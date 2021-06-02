------------------------------------------------------------------------------
--                              C C G                                       --
--                                                                          --
--                     Copyright (C) 2020-2021, AdaCore                     --
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

with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Strings.Fixed;       use Ada.Strings.Fixed;

with Interfaces.C; use Interfaces.C;

with Lib;    use Lib;
with Opt;    use Opt;
with Output; use Output;
with Sinput; use Sinput;

with GNATLLVM.Wrapper; use GNATLLVM.Wrapper;

with CCG.Aggregates;   use CCG.Aggregates;
with CCG.Environment;  use CCG.Environment;
with CCG.Instructions; use CCG.Instructions;
with CCG.Output;       use CCG.Output;
with CCG.Utils;        use CCG.Utils;

package body CCG.Subprograms is

   function Is_Builtin_Name (S : String) return Boolean is
     (S'Length > 5 and then S (S'First .. S'First + 4) = "llvm.");
   --  Return True if S denotes an LLVM builtin function

   function Call_Builtin
     (V : Value_T; S : String; Ops : Value_Array) return Boolean
      with Pre => Get_Opcode (V) = Op_Call;
   --  Call V, a call to a builtin function whose name is S, with operands
   --  of Ops. Return True if the builtin is handled and supported, False
   --  otherwise.

   function Effective_Return_Type (T : Type_T) return Str
     with Pre  => Get_Type_Kind (T) = Function_Type_Kind,
          Post => Present (Effective_Return_Type'Result);
   --  Return a string corresponding to the return type of T, adjusting the
   --  type in the case where it's an array.

   --------------------
   -- New_Subprogram --
   --------------------

   procedure New_Subprogram (V : Value_T) is
   begin
      Subprogram_Table.Append ((Func       => V,
                                First_Decl => Empty_Local_Decl_Idx,
                                Last_Decl  => Empty_Local_Decl_Idx,
                                First_Stmt => Empty_Stmt_Idx,
                                Last_Stmt  => Empty_Stmt_Idx));
   end New_Subprogram;

   ---------------
   -- Curr_Func --
   ---------------

   function Curr_Func return Value_T is
     (Subprogram_Table.Table (Subprogram_Table.Last).Func);

   ---------------------------------
   -- Write_Function_Type_Typedef --
   ---------------------------------

   procedure Write_Function_Type_Typedef (T : Type_T) is
      Fn_T : constant Type_T := Get_Element_Type (T);

   begin
      Write_Str ("typedef " & Function_Proto (Fn_T, "(*" & T & ")") & ";",
                 Eol => True);
   end Write_Function_Type_Typedef;

   ---------------------------
   -- Effective_Return_Type --
   ---------------------------

   function Effective_Return_Type (T : Type_T) return Str is
      Ret_Typ : constant Type_T := Get_Return_Type (T);

   begin
      --  If this function returns an array, change it to return a
      --  struct containing that array.

      if Get_Type_Kind (Ret_Typ) = Array_Type_Kind then
         Maybe_Write_Array_Return_Typedef (Ret_Typ);
         return Ret_Typ & "_R";
      else
         return +Ret_Typ;
      end if;
   end Effective_Return_Type;

   --------------------
   -- Function_Proto --
   --------------------

   function Function_Proto
     (V : Value_T; Extern : Boolean := False) return Str
   is
      Num_Params : constant Nat    := Count_Params (V);
      Fn_Typ     : constant Type_T := Get_Element_Type (V);
      Result     : Str             :=
        Effective_Return_Type (Fn_Typ) & " " & V & " (";

   begin
      --  If this is an internal subprogram, mark it as static

      if Get_Linkage (V) = Internal_Linkage then
         Result := "static " & Result;
      end if;

      --  If this doesn't return mark that

      if Does_Not_Return (V) then
         Result := "__attribute__((noreturn)) " & Result;
      end if;

      --  Indicate if this returns unsigned

      if Get_Is_Unsigned (V) then
         Result := "unsigned " & Result;
      end if;

      --  Then output the list of parameter types, if any.  If this isn't
      --  for an extern definition, include the parameter names.

      if Num_Params = 0 then
         Result := Result & "void";
      else
         for J in 0 .. Num_Params - 1 loop
            declare
               Param : constant Value_T := Get_Param (V, J);

            begin
               Result :=
                 Result & (if J = 0 then "" else ", ") & (Param + Write_Type);

               if not Extern then
                  Result := Result & " " & Param;
               end if;
            end;
         end loop;
      end if;

      return Result & ")";
   end Function_Proto;

   --------------------
   -- Function_Proto --
   --------------------

   function Function_Proto (T : Type_T; S : Str) return Str is
      Num_Params : constant Nat    := Count_Param_Types (T);
      P_Types    : Type_Array (1 .. Num_Params);
      First      : Boolean         := True;
      Result     : Str             :=
        Effective_Return_Type (T) & " " & S & " (";

   begin
      if Num_Params = 0 then
         Result := Result & "void";
      else
         Get_Param_Types (T, P_Types'Address);
         for T of P_Types loop
            begin
               Result := Result & (if First then "" else ", ") & T;
               First := False;
            end;
         end loop;
      end if;

      return Result & ")";

   end Function_Proto;

   ------------------------
   -- Declare_Subprogram --
   ------------------------

   procedure Declare_Subprogram (V : Value_T) is
      S        : constant String        := Get_Value_Name (V);

   begin
      --  Ignore LLVM builtin functions. The most we can have is a declaration
      --  but we don't want them to be emitted: we either handle or don't
      --  handle the builtin, but will never actually call it. We also don't
      --  emit declarations for C functions that are defined in string.h or
      --  stdlib.h.
      --  ??? Exactly how to get that list is far from clear, but let's
      --  approximate for now.

      if Is_Builtin_Name (S)
        or else S = "memcpy" or else S = "memmove" or else S = "memset"
        or else S = "memcmp" or else S = "malloc" or else S = "free"
      then
         return;
      end if;

      --  Otherwise, write the definition of this function. If it has no
      --  basic blocks, it must be an extern.

      Write_Str ((if No (Get_First_Basic_Block (V)) then "extern " else "") &
        Function_Proto (V, Extern => True) & ";" & Eol_Str);

   end Declare_Subprogram;

   -----------------------
   -- Output_Subprogram --
   -----------------------

   procedure Output_Subprogram (V : Value_T) is
   begin
      --  If there are no blocks, we have nothing to do

      if No (Get_First_Basic_Block (V)) then
         return;
      end if;

      --  Otherwise, start a new function and output it, starting from
      --  the entry block.

      New_Subprogram (V);
      Output_Decl (Function_Proto (V), Semicolon => False, V => V);
      Output_Decl ("{", Semicolon => False, Indent_After => 4);
      Output_BB (Get_Entry_Basic_Block (V));

      --  There shouldn't be anything still pending now, but if there is,
      --  output it now since if we hold it to the next subprogram, it'll
      --  reference variables in this one.

      Process_Pending_Values;
      Output_Stmt ("}", Semicolon => False, Indent_Before => -4);

   end Output_Subprogram;

   ----------------------
   -- Call_Instruction --
   ----------------------

   procedure Call_Instruction (V : Value_T; Ops : Value_Array) is
      Func  : constant Value_T := Ops (Ops'Last);
      S     : constant String  := Get_Value_Name (Func);
      Call  : Str              := Func + Component & " (";
      First : Boolean          := True;

   begin
      --  If this is a builtin, handle that

      if Is_Builtin_Name (S) then
         if Call_Builtin (V, S, Ops) then
            return;
         end if;

         --  By default generate a call to the builtin with a C-compatible
         --  name, to let users the chance to provide a suitable
         --  implementation.

         declare
            Builtin : String (S'Range);
         begin
            for J in S'Range loop
               Builtin (J) := (if S (J) = '.' then '_' else S (J));
            end loop;

            Error_Msg ("unsupported builtin: " & Builtin);
            Call :=
              "/* unsupported builtin */ " & (Builtin + Component) & " (";
         end;
      end if;

      --  Otherwise, generate the argument list for the call

      for Op of Ops (Ops'First .. Ops'Last - 1) loop
         if not First then
            Call := Call & ", ";
         end if;

         --  If Op is a constant array, we have to cast it to the non-constant
         --  type which is a pointer to the element type.

         if Get_Type_Kind (Op) = Array_Type_Kind and then Get_Is_Constant (Op)
         then
            Call :=
              Call & "(" & Get_Element_Type (Op) & " *) " & (Op + Comma);
         else
            Call := Call & (Op + Comma);
         end if;

         First := False;
      end loop;

      --  Add the final close paren, then write any pending values (we
      --  do it here to avoid writing out things only used as part of
      --  the parameter calculation. If this is a procedure call,
      --  output it. Otherwise, set this as the value of V.

      Call := (Call & ")") + Component;
      Process_Pending_Values;
      if Get_Type_Kind (V) = Void_Type_Kind then
         Output_Stmt (Call, V => V);
      else
         --  If this returns an array, we've changed it to returning a
         --  struct whose field is that array, so we need to do the
         --  dereference.  However, we can't simply return the function
         --  call followed by the dereference because if we're going to be
         --  using the entire array, we'll do a memmove and we can't take
         --  the address of the function result.  So we have to make a
         --  variable, assign the function result to it, and dereference
         --  that.  We don't have a value to use as the variable, so we
         --  have to use a bit of a kludge. Note that we can't call
         --  Write_Copy here since it'll think that this is an array copy
         --  and use memmove.

         if Get_Type_Kind (V) = Array_Type_Kind then
            declare
               Our_Var : constant Str := "ccg_v" & Get_Output_Idx;

            begin
               Output_Decl (TP ("#T1_R ", V) & Our_Var, V => V);
               Output_Stmt (Our_Var & " = " & Call + Assign, V => V);
               Call := Our_Var & ".F" + Component;
            end;
         end if;

         Assignment (V, Call);
      end if;
   end Call_Instruction;

   function Matches
     (S, Name : String; Exact : Boolean := False) return Boolean
   is
     (S'Length >= Name'Length + 5
        and then (not Exact or else S'Length = Name'Length + 5)
        and then S (S'First + 5 .. S'First + Name'Length + 4) = Name);
   --  True iff the string Name is present starting at position 5 of S
   --  (after "llvm."). If Exact is true, there must be nothing following
   --  Name in S.

   type Arithmetic_Operation is (Add, Subtract);
   --  For now only support Add/Sub for overflow builtin

   function Op_With_Overflow
     (V    : Value_T;
      Ops  : Value_Array;
      S    : String;
      Arit : Arithmetic_Operation) return Boolean
     with Pre => Present (V) and then Ops'Length >= 2;
   --  Handle an arithmetic operation with overflow. Return True if we're able
   --  to process this builtin.

   Overflow_Declared : array (Arithmetic_Operation) of Boolean :=
     (others => False);

   function Memory_Operation
     (V : Value_T; Ops : Value_Array; S : String) return Boolean
     with Pre => Present (V) and then Ops'Length >= 3;
   --  Process memcpy, memmove, and memset. Return True if we're able to
   --  process this builtin.

   function Funnel_Shift
     (V : Value_T; Ops : Value_Array; Left : Boolean) return Boolean
     with Pre => Present (V) and then Ops'Length >= 3;
   --  Process a left or right funnel shift builtin. Return True if we're
   --  able to process this builtin

   ----------------------
   -- Op_With_Overflow --
   ----------------------

   function Op_With_Overflow
     (V    : Value_T;
      Ops  : Value_Array;
      S    : String;
      Arit : Arithmetic_Operation) return Boolean
   is
      Op1  : constant Value_T  := Ops (Ops'First);
      Op2  : constant Value_T  := Ops (Ops'First + 1);
      Subp : constant String   :=
        "system__arith_64__" & To_Lower (Arit'Image) & "_with_ovflo_check64";
      Bits : constant unsigned := unsigned'Value (S (S'First + 25 .. S'Last));

   begin
      Maybe_Decl (V);

      if not Overflow_Declared (Arit) then
         Write_Str ("extern long long " & Subp & " (long long, long long);");
         Write_Eol;
         Overflow_Declared (Arit) := True;
      end if;

      --  Overflow builtins are only generated by the LLVM optimizer (see
      --  lib/Transforms/InstCombineCompares.cpp), but we still want to
      --  handle them by calling the routines in System.Arith_64 even if
      --  this is clearly inefficient.
      --  The LLVM builtin deals with a struct containing two fields: the
      --  first is the integer result, the second is the overflow bit.  If
      --  the Arith_64 routine succeeds (does not raise an exception), it
      --  means that no overflow occurred so always clear the second field.
      --  ??? The front end is able to convert some overflow operations to
      --  direct comparison. We ought to do the same here. And if we do
      --  that, then we can emit the builtins in all cases and allow the
      --  LLVM optimizer to see the builtins, which should allow it to do a
      --  better job. But this is for later work; we need to get a better
      --  idea of the tradeoffs here.

      Write_Copy (+V & ".ccg_field_0",
                  "(" & Int_String (Pos (Bits)) & ") " & Subp &
                    " ((long long) " & Op1 & ", (long long) " & Op2 & ")",
                  Int_Type (Bits),
                  V => V);
      Write_Copy (+V & ".ccg_field_1", +"0", Int_Type (1), V => V);
      return True;
   end Op_With_Overflow;

   ------------------
   -- Funnel_Shift --
   ------------------

   function Funnel_Shift
     (V : Value_T; Ops : Value_Array; Left : Boolean) return Boolean
   is
      Op1      : constant Value_T := Ops (Ops'First);
      Op2      : constant Value_T := Ops (Ops'First + 1);
      Op3      : constant Value_T := Ops (Ops'First + 2);
      Size     : constant Nat     := Get_Scalar_Bit_Size (Op1);
      Cnt      : Nat;
      Sh1, Sh2 : Str;

   begin
      --  There are two cases here, where Op3 is an integer and where
      --  it isn't. The second is more complex.
      --  ??? We're not going to support the non-variable case until we
      --  see an occurence of it since it'll be hard to debug.

      if not Is_A_Constant_Int (Op3) then
         return False;
      end if;

      --  Otherwise, get the constant shift count and generate the OR of
      --  the two shifts.

      Cnt := Nat (Const_Int_Get_Z_Ext_Value (Op3));
      Sh1 := (Op1 + Shift) & (if Left then " << " else " >> ") & Cnt;
      Sh2 := (Op2 + Shift) & (if Left then " >> " else " << ") & (Size - Cnt);
      Assignment (V, (Sh1 & " | " & Sh2) + Bit, Is_Opencode_Builtin => True);
      return True;

   end Funnel_Shift;

   -----------------------
   --  Memory_Operation --
   -----------------------

   function Memory_Operation
     (V : Value_T; Ops : Value_Array; S : String) return Boolean
   is
      Op1    : constant Value_T := Ops (Ops'First);
      Op2    : constant Value_T := Ops (Ops'First + 1);
      Op3    : constant Value_T := Ops (Ops'First + 2);
      Result : Str;

   begin
      Result := S & " (" & Op1 & ", " & Op2 & ", " & Op3 & ")";
      Process_Pending_Values;
      Output_Stmt (Result, V => V);
      return True;
   end Memory_Operation;

   ------------------
   -- Call_Builtin --
   ------------------

   function Call_Builtin
     (V : Value_T; S : String; Ops : Value_Array) return Boolean
   is
   begin
      --  We ignore lifetime start/end call and an experimental noalias call.
      --  Also ignore stackrestore/stacksave calls: these are generated by
      --  the optimizer and in many cases the stack usage is actually zero
      --  or very low.
      --  ??? Not clear that we can do better for now.

      if Matches (S, "lifetime")
        or else Matches (S, "experimental.noalias.scope.decl")
        or else Matches (S, "stackrestore", True)
        or else Matches (S, "stacksave", True)
      then
         return True;

      --  Handle some overflow intrinsics

      elsif Matches (S, "sadd.with.overflow") then
         return Op_With_Overflow (V, Ops, S, Add);

      elsif Matches (S, "ssub.with.overflow") then
         return Op_With_Overflow (V, Ops, S, Subtract);

      --  Handle funnel shifts

      elsif Matches (S, "fshl") then
         return Funnel_Shift (V, Ops, Left => True);
      elsif Matches (S, "fshr") then
         return Funnel_Shift (V, Ops, Left => False);

      --  We process memcpy, memmove, and memset by calling the corresponding
      --  C library function.

      elsif Matches (S, "memcpy") then
         return Memory_Operation (V, Ops, "memcpy");
      elsif Matches (S, "memmove") then
         return Memory_Operation (V, Ops, "memmove");
      elsif Matches (S, "memset") then
         return Memory_Operation (V, Ops, "memset");

      --  And we don't process the rest

      else
         return False;
      end if;

   end Call_Builtin;

   ------------------------
   -- Return_Instruction --
   ------------------------

   procedure Return_Instruction (V : Value_T; Op : Value_T) is
   begin
      --  If our function is marked no-return, we don't do anything.
      --  Otherwise, handle the cases with and without a value to return.

      if Does_Not_Return (Curr_Func) then
         null;
      elsif Present (Op) then

         --  If we're returning an array, declare a value (we can use V even
         --  though its LLVM type is void) of the struct type corresponding
         --  to Op's type, assign Op into its only field (which will be done
         --  with a memmove), and return that value.

         if Get_Type_Kind (Op) = Array_Type_Kind then
            Output_Decl (TP ("#T1_R #2", Op, V), V => V);
            Write_Copy (V & ".F", Op, Type_Of (Op));
            Output_Stmt (TP ("return #1", V), V => V);
         else
            Output_Stmt ("return " & Op + Assign, V => V);
         end if;
      else
         Output_Stmt ("return", V => V);
      end if;
   end Return_Instruction;

   -----------------------
   -- Write_Subprograms --
   -----------------------

   procedure Write_Subprograms is
   begin

      --  Start by writing out the global decls

      for Gidx in Global_Decl_Idx_Start .. Get_Last_Global_Decl loop
         Write_Line (Get_Global_Decl_Line (Gidx));
      end loop;

      --  Now write out each subprogram

      for Sidx in Subprogram_Idx_Start .. Subprogram_Table.Last loop
         declare
            SD : constant Subprogram_Data := Subprogram_Table.Table (Sidx);

         begin
            --  First write the decls. We at least have the function prototype

            for Didx in SD.First_Decl .. SD.Last_Decl loop
               Write_Line (Get_Local_Decl_Line (Didx));
            end loop;

            --  If we're written more than just the prototype and the "{",
            --  add a blank line between the decls and statements.

            if SD.Last_Decl > SD.First_Decl + 1 then
               Write_Eol;
            end if;

            --  Then write the statements. We at least have the closing brace.

            for Sidx in SD.First_Stmt .. SD.Last_Stmt loop
               Write_Line (Get_Stmt_Line (Sidx));
            end loop;
         end;
      end loop;
   end Write_Subprograms;
end CCG.Subprograms;
