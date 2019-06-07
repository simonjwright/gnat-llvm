------------------------------------------------------------------------------
--                             G N A T - L L V M                            --
--                                                                          --
--                     Copyright (C) 2013-2019, AdaCore                     --
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

with LLVM.Core;       use LLVM.Core;

with Opt;    use Opt;
with Sinput; use Sinput;
with Table;  use Table;

with GNATLLVM.Codegen;     use GNATLLVM.Codegen;
with GNATLLVM.Environment; use GNATLLVM.Environment;
with GNATLLVM.GLType;      use GNATLLVM.GLType;
with GNATLLVM.Subprograms; use GNATLLVM.Subprograms;
with GNATLLVM.Types;       use GNATLLVM.Types;
with GNATLLVM.Utils;       use GNATLLVM.Utils;
with GNATLLVM.Wrapper;     use GNATLLVM.Wrapper;

package body GNATLLVM.DebugInfo is

   --  We maintain a stack of debug info contexts, with the outermost
   --  context being global (??? not currently supported), then a subprogram,
   --  and then lexical blocks.

   Debug_Scope_Low_Bound : constant := 1;

   type Debug_Scope is record
      SFI   : Source_File_Index;
      --  Source file index for this scope

      Scope : Metadata_T;
      --  LLVM debugging metadata for this scope
   end record;

   package Debug_Scope_Table is new Table.Table
     (Table_Component_Type => Debug_Scope,
      Table_Index_Type     => Nat,
      Table_Low_Bound      => Debug_Scope_Low_Bound,
      Table_Initial        => 10,
      Table_Increment      => 5,
      Table_Name           => "Debug_Scope_Table");
   --  Table of debugging scopes. The last inserted scope point corresponds
   --  to the current scope.

   function Has_Debug_Scope return Boolean is
     (Debug_Scope_Table.Last >= Debug_Scope_Low_Bound);
   --  Says whether we do or don't currently have a debug scope.
   --  Won't be needed when we support a global scope.

   function Current_Debug_Scope return Metadata_T is
     (Debug_Scope_Table.Table (Debug_Scope_Table.Last).Scope)
     with Post => Present (Current_Debug_Scope'Result);
   --  Current debug info scope

   function Current_Debug_SFI return Source_File_Index is
     (Debug_Scope_Table.Table (Debug_Scope_Table.Last).SFI);
   --  Current debug info source file index

   Freeze_Pos_Level : Natural := 0;
   --  Current level of pushes of requests to freeze debug position

   ----------------------
   -- Push_Debug_Scope --
   ----------------------

   procedure Push_Debug_Scope (SFI : Source_File_Index; Scope : Metadata_T) is
   begin
      if Emit_Debug_Info then
         Debug_Scope_Table.Append ((SFI, Scope));
      end if;
   end Push_Debug_Scope;

   ---------------------
   -- Pop_Debug_Scope --
   ---------------------

   procedure Pop_Debug_Scope is
   begin
      if Emit_Debug_Info and then not Library_Level then
         Debug_Scope_Table.Decrement_Last;
      end if;
   end Pop_Debug_Scope;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      if Emit_Debug_Info then
         Add_Debug_Flags (Module);
         DI_Builder         := Create_DI_Builder (Module);
         Debug_Compile_Unit :=
           DI_Create_Compile_Unit
           (DI_Builder,
            (if   Ada_Version = Ada_83 then DWARF_Source_Language_Ada83
             else DWARF_Source_Language_Ada95),
            Get_Debug_File_Node (Main_Source_File), "GNAT/LLVM", 9,
            Code_Gen_Level /= Code_Gen_Level_None, "", 0, 0, "", 0,
            DWARF_Emission_Full, 0, False, False);
      end if;
   end Initialize;

   ------------------------
   -- Finalize_Debugging --
   ------------------------

   procedure Finalize_Debugging is
   begin
      if Emit_Debug_Info then
         DI_Builder_Finalize (DI_Builder);
      end if;
   end Finalize_Debugging;

   -------------------------
   -- Get_Debug_File_Node --
   -------------------------

   function Get_Debug_File_Node (File : Source_File_Index) return Metadata_T is
   begin
      if DI_Cache = null then
         DI_Cache :=
           new DI_File_Cache'(1 .. Last_Source_File => No_Metadata_T);
      end if;

      if DI_Cache (File) /= No_Metadata_T then
         return DI_Cache (File);
      end if;

      declare
         Full_Name : constant String     :=
           Get_Name_String (Full_Debug_Name (File));
         Name      : constant String     :=
           Get_Name_String (Debug_Source_Name (File));
         DIFile    : constant Metadata_T :=
           DI_Create_File (DI_Builder, Name, UL (Name'Length),
                           Full_Name (1 .. Full_Name'Length - Name'Length),
                           UL (Full_Name'Length - Name'Length));
      begin
         DI_Cache (File) := DIFile;
         return DIFile;
      end;
   end Get_Debug_File_Node;

   ----------------------------------
   -- Create_Subprogram_Debug_Info --
   ----------------------------------

   function Create_Subprogram_Debug_Info
     (Func           : GL_Value;
      Def_Ident      : Entity_Id;
      N              : Node_Id;
      Name, Ext_Name : String) return Metadata_T
   is
      Types     : constant Type_Array (1 .. 0) := (others => <>);
      Result    : Metadata_T;
      pragma Unreferenced (Def_Ident);
   begin
      if Emit_Debug_Info then
         Result := DI_Create_Function
           (DI_Builder,
            Get_Debug_File_Node (Get_Source_File_Index (Sloc (N))),
            Name, Name'Length, Ext_Name, Ext_Name'Length,
            Get_Debug_File_Node (Get_Source_File_Index (Sloc (N))),
            unsigned (Get_Logical_Line_Number (Sloc (N))),
            DI_Builder_Create_Subroutine_Type
              (DI_Builder,
               Get_Debug_File_Node (Get_Source_File_Index (Sloc (N))),
               Types'Address, 0, DI_Flag_Zero),
            False, True, unsigned (Get_Logical_Line_Number (Sloc (N))),
            DI_Flag_Zero, Code_Gen_Level /= Code_Gen_Level_None);

         Set_Subprogram (LLVM_Value (Func), Result);
         return Result;
      else
         return No_Metadata_T;
      end if;
   end Create_Subprogram_Debug_Info;

   ------------------------------
   -- Push_Lexical_Debug_Scope --
   ------------------------------

   procedure Push_Lexical_Debug_Scope (N : Node_Id) is
      SFI : constant Source_File_Index := Get_Source_File_Index (Sloc (N));

   begin
      if Emit_Debug_Info and then not Library_Level then
         Push_Debug_Scope
           (SFI, DI_Builder_Create_Lexical_Block
              (DI_Builder, Current_Debug_Scope, Get_Debug_File_Node (SFI),
               unsigned (Get_Logical_Line_Number (Sloc (N))),
               unsigned (Get_Column_Number (Sloc (N)))));
      end if;
   end Push_Lexical_Debug_Scope;

   ---------------------------
   -- Push_Debug_Freeze_Pos --
   ---------------------------

   procedure Push_Debug_Freeze_Pos is
   begin
      Freeze_Pos_Level := Freeze_Pos_Level + 1;
   end Push_Debug_Freeze_Pos;

   --------------------------
   -- Pop_Debug_Freeze_Pos --
   --------------------------

   procedure Pop_Debug_Freeze_Pos is
   begin
      Freeze_Pos_Level := Freeze_Pos_Level - 1;
   end Pop_Debug_Freeze_Pos;

   ---------------------------
   -- Set_Debug_Pos_At_Node --
   ---------------------------

   procedure Set_Debug_Pos_At_Node (N : Node_Id) is
      SFI : constant Source_File_Index := Get_Source_File_Index (Sloc (N));

   begin
      if Emit_Debug_Info and then Has_Debug_Scope
        and then Freeze_Pos_Level = 0 and then SFI = Current_Debug_SFI
      then
         Set_Current_Debug_Location
           (IR_Builder,
            Metadata_As_Value
              (Context,
               (DI_Builder_Create_Debug_Location
                  (Context, unsigned (Get_Logical_Line_Number (Sloc (N))),
                   unsigned (Get_Column_Number (Sloc (N))),
                   Current_Debug_Scope, No_Metadata_T))));
      end if;
   end Set_Debug_Pos_At_Node;

   ----------------------------
   -- Create_Debug_Type_Data --
   ----------------------------

   function Create_Debug_Type_Data (GT : GL_Type) return Metadata_T is
      TE     : constant Entity_Id := Full_Etype (GT);
      Name   : constant String   := Get_Name (TE);
      T      : constant Type_T   := Type_Of (GT);
      Size   : constant UL       :=
        (if   Type_Is_Sized (T) then UL (ULL'(Get_Type_Size_In_Bits (T)))
         else 0);
      Align  : constant unsigned :=
        unsigned (Nat'(Get_Type_Alignment (GT)) * BPU);
      Result : Metadata_T        := Get_Debug_Type (TE);

   begin
      --  If we already made debug info for this type, return it

      if Present (Result) then
         return Result;

      --  Do nothing if not emitting debug info or if we've already
      --  seen this type as part of elaboration (e.g., an access type that
      --  points to itself).  ???  We really should use an incomplete type
      --  in that last case.

      elsif not Emit_Debug_Info or else Is_Being_Elaborated (TE) then
         return No_Metadata_T;
      end if;

      --  Mark as being elaborated and create debug information based on
      --  the kind of the type.

      Set_Is_Being_Elaborated (TE, True);
      case Ekind (GT) is
         when E_Signed_Integer_Type | E_Signed_Integer_Subtype
            | E_Modular_Integer_Type | E_Modular_Integer_Subtype =>
            Result := DI_Create_Basic_Type
              (DI_Builder, Name, Name'Length, Size,
               (if    Size = UL (BPU)
                then  (if   Is_Unsigned_Type (GT) then DW_ATE_Unsigned_Char
                       else DW_ATE_Signed_Char)
                elsif Is_Unsigned_Type (GT) then DW_ATE_Unsigned
                else  DW_ATE_Signed),
               DI_Flag_Zero);

         when Float_Kind =>
            Result := DI_Create_Basic_Type (DI_Builder, Name, Name'Length,
                                            Size, DW_ATE_Float, DI_Flag_Zero);
         when Access_Kind =>

            declare
               Inner_Type : constant Metadata_T :=
                 Create_Debug_Type_Data (Full_Designated_GL_Type (GT));

            begin
               if Present (Inner_Type) then
                  Result := DI_Create_Pointer_Type
                    (DI_Builder, Inner_Type, Size, Align, 0,
                     Name, Name'Length);
               end if;
            end;

         when others =>
            null;
      end case;

      --  Show no longer elaborating this type and save and return the result

      Set_Is_Being_Elaborated (TE, False);
      Set_Debug_Type (TE, Result);
      return Result;
   end Create_Debug_Type_Data;

   --------------------------------------
   -- Build_Global_Variable_Debug_Data --
   --------------------------------------

   procedure Build_Global_Variable_Debug_Data
     (Def_Ident : Entity_Id; V : GL_Value)
   is
      GT        : constant GL_Type    := Related_Type (V);
      Type_Data : constant Metadata_T := Create_Debug_Type_Data (GT);
      Name      : constant String     := Get_Name (Def_Ident);
      Exp_Arr   : aliased stdint_h.int64_t;
      Expr      : Metadata_T;
      GVE       : Metadata_T;

   begin
      if Emit_Debug_Info and then Present (Type_Data)
        and then Relationship (V) = Reference
      then
         Expr := DI_Builder_Create_Expression (DI_Builder, Exp_Arr'Access, 0);

         GVE := DI_Create_Global_Variable_Expression
           (DI_Builder, Debug_Compile_Unit, Name, Name'Length, "", 0,
            Get_Debug_File_Node (Get_Source_File_Index (Sloc (Def_Ident))),
            unsigned (Get_Logical_Line_Number (Sloc (Def_Ident))),
            Type_Data, False, Expr, No_Metadata_T,
            unsigned (Nat'(Get_Type_Alignment (GT)) * BPU));

         Global_Set_Metadata (LLVM_Value (V), 0, GVE);
      end if;
   end Build_Global_Variable_Debug_Data;

end GNATLLVM.DebugInfo;
