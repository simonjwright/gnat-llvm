------------------------------------------------------------------------------
--                              C C G                                       --
--                                                                          --
--                     Copyright (C) 2020-2022, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Atree;      use Atree;
with Uintp.LLVM; use Uintp.LLVM;

with GNATLLVM.Codegen; use GNATLLVM.Codegen;
with GNATLLVM.Types;   use GNATLLVM.Types;
with GNATLLVM.Wrapper; use GNATLLVM.Wrapper;

with CCG.Environment;  use CCG.Environment;
with CCG.Instructions; use CCG.Instructions;
with CCG.Output;       use CCG.Output;

package body CCG.Aggregates is

   --  This package contains routines used to process aggregate data,
   --  which are arrays and structs.

   function Value_Piece (V : Value_T; T : in out Type_T; Idx : Nat) return Str
     with Pre  => Get_Opcode (V) in Op_Extract_Value | Op_Insert_Value
                  and then Is_Aggregate_Type (T),
          Post => Present (Value_Piece'Result) and then T /= T'Old;
   --  T is the type of a component of the aggregate in an extractvalue or
   --  insertvalue instruction V. Return an Str saying how to access that
   --  component and update T to be the type of that component.

   -----------------------
   -- Default_Alignment --
   -----------------------

   function Default_Alignment (T : Type_T) return Nat is
   begin
      --  As documented in the spec of this package, we have three cases,
      --  arrays, structs, and non-composite types

      if Is_Array_Type (T) then
         return Default_Alignment (Get_Element_Type (T));

      elsif Is_Struct_Type (T) then
         declare
            Types : constant Nat := Count_Struct_Element_Types (T);

         begin
            return Max_Align : Nat := BPU do
               for J in 0 .. Types - 1 loop
                  Max_Align :=
                    Nat'Max (Actual_Alignment
                               (Struct_Get_Type_At_Index (T, J)),
                             Max_Align);
               end loop;
            end return;
         end;
      else
         return Get_Type_Alignment (T);
      end if;

   end Default_Alignment;

   ----------------------
   -- Struct_Out_Style --
   ----------------------

   function Struct_Out_Style (T : Type_T) return Struct_Out_Style_T is
      Types     : constant Nat              := Count_Struct_Element_Types (T);
      F0        : constant Entity_Id        :=
        (if Types = 0 then Empty else Get_Field_Entity (T, 0));
      TE        : constant Opt_Type_Kind_Id :=
        (if   Present (F0) then Full_Base_Type (Full_Etype (Scope (F0)))
         else Empty);
      Cur_Pos   :  ULL                      := 0;
      Need_Pack : Boolean                   := False;
      Need_Pad  : Boolean                   := False;

   begin
      --  If this isn't a packed struct, we don't need packing. Likewise if
      --  there are no fields. But we don't know that we can omit padding
      --  fields.

      if not Is_Packed_Struct (T)
        or else Count_Struct_Element_Types (T) = Nat (0)
      then
         return Padding;

      --  if we can't determine the base type, its base type is
      --  unconstrained (see the discussion in GNATLLVM.Records.Create for
      --  the rationale of this test), or if the alignment of the struct
      --  is smaller that the default alignment, we must pack.

      elsif No (TE) or else not Is_Constrained (TE)
        or else (+Alignment (TE)) * UBPU < ULL (Default_Alignment (T))
      then
         return Packed;

      --  ??? For now, if optimizing, we need to include padding
      --  fields since LLVM's SROA may try to preserve padding fields.

      elsif Code_Opt_Level > 0 then
         Need_Pad := True;
      end if;

      --  Now we look at the position of each field relative to its default
      --  position. Skip padding fields when doing this.

      for J in 0 .. Types - 1 loop
         declare
            Actual_Pos : constant ULL    :=
              To_Bits (Get_Element_Offset (T, J));
            Elem_T     : constant Type_T := Struct_Get_Type_At_Index (T, J);
            Size       : constant ULL    := Get_Type_Size (Elem_T);
            Align      : constant ULL    := ULL (Actual_Alignment (Elem_T));
            SB_Pos     : constant ULL    :=
              (Cur_Pos + Align - 1) / Align * Align;

         begin
            if not Is_Field_Padding (T, J) then
               if Actual_Pos < SB_Pos then
                  Need_Pack := True;
               elsif Actual_Pos > SB_Pos then
                  Need_Pad  := True;
               end if;

               Cur_Pos := Cur_Pos + Size;
            end if;

            --  ??? If we have a zero-length array, we may be doing an
            --  reference to that field, which won't work properly if we
            --  make any changes here, so keep that record packed for now.
            --  This is a major kludge and we have to figure out the proper
            --  way of referencing such a field.

            if Is_Zero_Length_Array (Elem_T) then
               Need_Pack := True;
            end if;
         end;
      end loop;

      return (if   Need_Pack then Packed elsif Need_Pad then Padding
              else Normal);

   end Struct_Out_Style;

   ---------------------------
   -- Output_Struct_Typedef --
   ---------------------------

   procedure Output_Struct_Typedef (T : Type_T; Incomplete : Boolean := False)
   is
      Types   : constant Nat                := Count_Struct_Element_Types (T);
      TE      : constant Opt_Type_Kind_Id   := Get_Entity (T);
      Is_Vol  : constant Boolean            :=
        Present (TE) and then Treat_As_Volatile (TE);
      Vol_Str : constant String             :=
        (if Is_Vol then "volatile " else "");
      SOS     : constant Struct_Out_Style_T := Struct_Out_Style (T);

   begin
      --  Because this struct may contain a pointer to itself, we always have
      --  to write an incomplete struct. So we write, e.g.,
      --
      --       typedef struct foo foo;
      --       struct foo { ... full definition ..}

      if not Get_Is_Incomplete_Output (T) then
         Output_Decl ("typedef " & Vol_Str & "struct " & T & " " & T,
                      Is_Typedef => True);
         Set_Is_Incomplete_Output (T);
      end if;

      --  If all we're to do is to output the incomplete definition,
      --  we're done.

      if Incomplete then
         return;
      end if;

      --  Before we output the typedef for this struct, make sure we've
      --  output any inner typedefs.

      for J in 0 .. Types - 1 loop
         Maybe_Output_Typedef (Struct_Get_Type_At_Index (T, J));
      end loop;

      --  Now that we know that all inner typedefs have been output,
      --  we output the struct definition.

      Output_Decl ("struct " & T, Semicolon => False, Is_Typedef => True);
      Start_Output_Block (Decl);
      for J in 0 .. Types - 1 loop

         declare
            ST : constant Type_T := Struct_Get_Type_At_Index (T, J);

         begin
            --  If the type of a field is a zero-length array, this can
            --  indicate either a variable-sized array (usually for the last
            --  field) or an instance of a variable-sized array where the
            --  size is zero.  In either case, if we write it as an array of
            --  length one, the size of the struct will be different than
            --  expected, but not all versions of C support 0-sized arrays.
            --  ??? We may want to adjust what we do here as we add
            --  functionality to support various different C compiler
            --  options.

            if not Is_Zero_Length_Array (ST)
              and then not (SOS = Normal and then Is_Field_Padding (T, J))
            then
               declare
                  Name           : constant Str                      :=
                    Get_Field_Name (T, J);
                  F              : constant Opt_Record_Field_Kind_Id :=
                    Get_Field_Entity (T, J);
                  F_Is_Vol       : constant Boolean                  :=
                    Present (F) and then Treat_As_Volatile (F)
                    and then not Is_Vol;

               begin
                  Output_Decl
                    ((ST or F) & (if F_Is_Vol then "volatile " else "") &
                      " " & Name,
                     Is_Typedef => True);
               end;
            end if;
         end;
      end loop;

      --  If this is an empty struct, we need to add a dummy field since
      --  ISO C89 doesn't allow an empty struct.

      if Types = 0 then
         Output_Decl ("char dummy_for_null_recordC", Is_Typedef => True);
      end if;

      --  ??? We have many ways of handling packed, but don't worry about that
      --  in the initial support.

      Output_Decl ("}" &
                     (if    SOS = Packed then " __attribute__ ((packed))"
                      else ""),
                   Is_Typedef => True, End_Block => Decl);
   end Output_Struct_Typedef;

   -------------------------
   -- Write_Array_Typedef --
   -------------------------

   procedure Output_Array_Typedef (T : Type_T) is
      Elem_T : constant Type_T := Get_Element_Type (T);

   begin
      Maybe_Output_Typedef (Elem_T);
      Output_Decl ("typedef " & Elem_T & " " & T & "[" &
                   Effective_Array_Length (T) & "]", Is_Typedef => True);
   end Output_Array_Typedef;

   ---------------------------------------
   -- Maybe_Output_Array_Return_Typedef --
   ---------------------------------------

   procedure Maybe_Output_Array_Return_Typedef (T : Type_T) is
   begin
      --  If we haven't written this yet, first ensure that we've written
      --  the typedef for T since we reference it, then write the actual
      --  typedef, and mark it as written.

      if not Get_Is_Return_Typedef_Output (T) then
         Maybe_Output_Typedef (T);
         Output_Decl ("typedef struct " & T & "_R {" & T & " F;} " & T & "_R",
                      Is_Typedef => True);
         Set_Is_Return_Typedef_Output (T);
      end if;
   end Maybe_Output_Array_Return_Typedef;

   -----------------
   -- Value_Piece --
   -----------------

   function Value_Piece
     (V : Value_T; T : in out Type_T; Idx : Nat) return Str is
   begin
      return Result : Str do
         declare
            Ins_Idx : constant Nat := Get_Index (V, Idx);
         begin
            --  We know this is either a struct or an array

            if Get_Type_Kind (T) = Struct_Type_Kind then
               Result := "." & Get_Field_Name (T, Ins_Idx) + Component;
               T      := Struct_Get_Type_At_Index (T, Ins_Idx);
            else
               Result := " [" & Ins_Idx & "]" + Component;
               T      := Get_Element_Type (T);
            end if;
         end;
      end return;
   end Value_Piece;

   -------------------------------
   -- Extract_Value_Instruction --
   -------------------------------

   function Extract_Value_Instruction (V : Value_T; Op : Value_T) return Str is
      Idxs : constant Nat := Get_Num_Indices (V);
      T    : Type_T       := Type_Of (Op);
   begin
      return Result : Str := Op + Component do

         --  We process each index in turn, stripping off the reference.

         for J in 0 .. Idxs - 1 loop
            Result := Result & Value_Piece (V, T, J);
         end loop;
      end return;
   end Extract_Value_Instruction;

   ------------------------------
   -- Insert_Value_Instruction --
   ------------------------------

   procedure Insert_Value_Instruction (V, Aggr, Op : Value_T) is
      Idxs : constant Nat := Get_Num_Indices (V);
      T    : Type_T       := Type_Of (Aggr);
      Acc  : Str          := +V;

   begin
      --  If Aggr is undef, we don't need to do any copy. Otherwise, we
      --  first copy it to the result variable.

      Maybe_Decl (V);
      if Is_Undef (Aggr) then
         null;
      else
         Output_Copy (V, +Aggr, T);
      end if;

      --  Next we generate the string that represents the access of this
      --  instruction.

      for J in 0 .. Idxs - 1 loop
         Acc := Acc & Value_Piece (V, T, J);
      end loop;

      --  The resulting type must be that of Op and we emit the assignment

      pragma Assert (T = Type_Of (Op));
      Output_Copy (Acc, Op + Assign, T, V);
   end Insert_Value_Instruction;

   ---------------------
   -- GEP_Instruction --
   ---------------------

   procedure GEP_Instruction (V : Value_T; Ops : Value_Array) is
      Aggr   : constant Value_T := Ops (Ops'First);
      --  The pointer to aggregate that we're dereferencing

      Aggr_T : Type_T           := Get_Element_Type (Aggr);
      --  The type that Aggr, which is always a pointer, points to

      Is_LHS : Boolean          := Get_Is_LHS (Aggr);
      --  Whether our result so far is an LHS as opposed to a pointer.
      --  If it is, then we can use normal derefrence operations and we must
      --  take the address at the end of the instruction processing.

      Result : Str;
      --  The resulting operation so far

   begin
      --  The first operand is special in that it represents a value to be
      --  multiplied by the size of the type pointed to and added to the
      --  value of the pointer input. Normally, we have a GEP that either
      --  has a nonzero value for this operand and no others or that has a
      --  zero for this value, but those aren't requirements. However, it's
      --  very worth special-casing the zero case here because we have
      --  nothing to do in that case.

      if Is_A_Constant_Int (Ops (Ops'First + 1))
        and then Equals_Int (Ops (Ops'First + 1), 0)
      then
         Result := Aggr + LHS + Component;
      else
         Result := TP ("#1[#2]", Aggr, Ops (Ops'First + 1)) + Component;
         Is_LHS := True;
      end if;

      --  Now process any other operands, which must always dereference into
      --  an array or struct. When we make a component reference of an object,
      --  we must ensure that the actual type of the object, not just a pointer
      --  to that object, will have been fully defined and isn't an incomplete
      --  type.

      for Op of Ops (Ops'First + 2 .. Ops'Last) loop
         Maybe_Output_Typedef (Aggr_T);
         if Get_Type_Kind (Aggr_T) = Array_Type_Kind then

            --  If this isn't an LHS, we have to make it one, but not if
            --  this is a zero-size array, since we've written the pointer
            --  type as a pointer to the element.

            if not Is_LHS and then Get_Array_Length (Aggr_T) /= Nat (0) then
               Result := Deref (Result) + Component;
            end if;

            Result := Result & TP ("[#1]", Op) + Component;
            Aggr_T := Get_Element_Type (Aggr_T);
            Is_LHS := True;

         else
            pragma Assert (Get_Type_Kind (Aggr_T) = Struct_Type_Kind);

            declare
               Idx   : constant Nat    := Nat (Const_Int_Get_S_Ext_Value (Op));
               ST    : constant Type_T :=
                 Struct_Get_Type_At_Index (Aggr_T, Idx);
               Found : Boolean         := False;

            begin
               --  If this is a zero-length array, it doesn't actually
               --  exist, so convert this into a cast to char *, point past
               --  the end of a previous non-zero-length-array field (or at
               --  the start of the struct if none) and then cast to a
               --  pointer to the array's element type.

               if Is_Zero_Length_Array (ST) then
                  for Prev_Idx in reverse 0 .. Idx - 1 loop
                     declare
                        Prev_ST : constant Type_T :=
                          Struct_Get_Type_At_Index (Aggr_T, Prev_Idx);
                        Ref     : constant Str    :=
                          Result & (if Is_LHS then "." else "->") +
                            Component & Get_Field_Name (Aggr_T, Prev_Idx);

                     begin
                        --  If we found a previous non-zero-length array
                        --  field, point to the end of it.

                        if not Is_Zero_Length_Array (Prev_ST) then
                           Result := ("(char *) " & Addr_Of (Ref) &
                                        " + sizeof (" & Ref & ")");
                           Found  := True;
                           exit;
                        end if;
                     end;
                  end loop;

                  --  If we haven't found such a field, point to the beginning
                  --  of the object.

                  if not Found then
                     Result := "(char *) " &
                       (if Is_LHS then Addr_Of (Result) else Result);
                  end if;

                  --  Now cast to the desired type

                  Result :=
                    "((" & Get_Element_Type (ST) & " *) (" & Result & "))";
                  Is_LHS := False;

               --  Otherwise, just do a normal field reference

               else
                  Result :=
                    Result & (if Is_LHS then "." else "->") + Component &
                      Get_Field_Name (Aggr_T, Idx);
                  Is_LHS := True;
               end if;

               Aggr_T := ST;
            end;
         end if;
      end loop;

      --  If the input is a constant, mark the output as constant and
      --  as the value of V, mark as LHS if it is,a and we're done.

      if Get_Is_Constant (Aggr) then
         Set_Is_Constant (V);
         Set_Is_LHS (V, Is_LHS);
         Set_C_Value (V, Result);
         return;
      end if;

      --  If we ended up with a LHS, we set this as the value of V but mark
      --  it as an LHS. This is to avoid taking an address and then doing a
      --  dereference for nested GEP's.

      Set_Is_LHS (V, Is_LHS);
      if Is_LHS then
         Set_C_Value (V, Result);
      else
         Assignment (V, Result);
      end if;

   end GEP_Instruction;

end CCG.Aggregates;
