------------------------------------------------------------------------------
--                              C C G                                       --
--                                                                          --
--                     Copyright (C) 2020-2023, AdaCore                     --
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

with Ada.Containers.Hashed_Sets;

with Interfaces.C;

with LLVM.Types; use LLVM.Types;

with Einfo.Entities; use Einfo.Entities;
with Namet;          use Namet;
with Sinfo.Nodes;    use Sinfo.Nodes;
with Types;          use Types;

with GNATLLVM; use GNATLLVM;

package CCG is

   subtype unsigned is Interfaces.C.unsigned;

   --  This package and its children generate C code from the LLVM IR
   --  generated by GNAT LLLVM.

   Typedef_Idx_Low_Bound      : constant := 100_000_000;
   Typedef_Idx_High_Bound     : constant := 199_999_999;
   type Typedef_Idx is
     range Typedef_Idx_Low_Bound .. Typedef_Idx_High_Bound;
   Typedef_Idx_Start          : constant Typedef_Idx     :=
     Typedef_Idx_Low_Bound + 1;

   Global_Decl_Idx_Low_Bound  : constant := 200_000_000;
   Global_Decl_Idx_High_Bound : constant := 299_999_999;
   type Global_Decl_Idx is
     range Global_Decl_Idx_Low_Bound .. Global_Decl_Idx_High_Bound;
   Global_Decl_Idx_Start      : constant Global_Decl_Idx :=
     Global_Decl_Idx_Low_Bound + 1;
   Empty_Global_Decl_Idx      : constant Global_Decl_Idx  :=
     Global_Decl_Idx_Low_Bound;

   Local_Decl_Idx_Low_Bound   : constant := 300_000_000;
   Local_Decl_Idx_High_Bound  : constant := 399_999_999;
   type Local_Decl_Idx is
     range Local_Decl_Idx_Low_Bound .. Local_Decl_Idx_High_Bound;
   Empty_Local_Decl_Idx       : constant Local_Decl_Idx  :=
     Local_Decl_Idx_Low_Bound;

   Stmt_Idx_Low_Bound         : constant := 400_000_000;
   Stmt_Idx_High_Bound        : constant := 499_999_999;
   type Stmt_Idx is range Stmt_Idx_Low_Bound .. Stmt_Idx_High_Bound;
   Empty_Stmt_Idx             : constant Stmt_Idx        :=
     Stmt_Idx_Low_Bound;

   Flow_Idx_Low_Bound         : constant := 500_000_000;
   Flow_Idx_High_Bound        : constant := 599_999_999;
   type Flow_Idx is range Flow_Idx_Low_Bound .. Flow_Idx_High_Bound;
   Empty_Flow_Idx             : constant Flow_Idx := Flow_Idx_Low_Bound;

   --  Line_Idx is 6xx_xxx_xxx, Case_Idx is 7xx_xxx_xxx, and If_Idx is
   --  8xx_xxx_xxx (in ccg-flow.ads). Subprogram_Idx (in ccg-subprograms.adb)
   --  is 9xx_xxx_xxx.

   --  We output any typedefs at the time we decide that we need it and
   --  also output decls for any global variables at a similar time.
   --  However, we keep lists of subprograms and decls and statements for
   --  each and only write those after we've finished processing the module
   --  so that all typedefs and globals are written first.  These
   --  procedures manage those lists.

   function Present (Idx : Global_Decl_Idx) return Boolean is
     (Idx /= Empty_Global_Decl_Idx);
   function Present (Idx : Local_Decl_Idx)  return Boolean is
     (Idx /= Empty_Local_Decl_Idx);
   function Present (Idx : Stmt_Idx)        return Boolean is
     (Idx /= Empty_Stmt_Idx);
   function Present (Idx : Flow_Idx)        return Boolean is
    (Idx /= Empty_Flow_Idx);

   function No (Idx : Global_Decl_Idx)      return Boolean is
     (Idx = Empty_Global_Decl_Idx);
   function No (Idx : Local_Decl_Idx)       return Boolean is
     (Idx = Empty_Local_Decl_Idx);
   function No (Idx : Stmt_Idx)             return Boolean is
     (Idx = Empty_Stmt_Idx);
   function No (Idx : Flow_Idx)             return Boolean is
     (Idx = Empty_Flow_Idx);

   package Value_Sets is new Ada.Containers.Hashed_Sets
     (Element_Type        => Value_T,
      Hash                => Hash_Value,
      Equivalent_Elements => "=");

   package BB_Sets is new Ada.Containers.Hashed_Sets
     (Element_Type        => Basic_Block_T,
      Hash                => Hash_BB,
      Equivalent_Elements => "=");

   Has_Access_Subtype : Boolean := False;
   --  If True, we need to use our generic "ccg_f" type for a function pointer

   Lowest_Line_Number : Physical_Line_Number := Physical_Line_Number'First;
   --  The lowest line number of any object that we're writting out

   procedure C_Initialize_Output;
   --  Do any initialization needed to output C.  This is always called after
   --  we've obtained target parameters.

   procedure C_Generate (Module : Module_T);
   --  The main procedure, which generates C code from the LLVM IR

   procedure C_Add_To_Source_Order (N : Node_Id)
     with Pre => Nkind (N) in N_Pragma | N_Subprogram_Declaration |
                              N_Subprogram_Body | N_Object_Declaration |
                              N_Object_Renaming_Declaration |
                              N_Exception_Declaration |
                              N_Exception_Renaming_Declaration;
   --  Add N to the list of file-level objects present in the source if
   --  it indeed does come from the source.

   procedure C_Protect_Source_Order;
   --  Make a pass over everything we added to the source order and
   --  set up to be notified if any of them have been deleted.

   procedure C_Set_Field_Info
     (UID         : Unique_Id;
      Idx         : Nat;
      Name        : Name_Id   := No_Name;
      Entity      : Entity_Id := Empty;
      Is_Padding  : Boolean   := False;
      Is_Bitfield : Boolean   := False);
   --  Say what field Idx in the struct temporarily denoted by SID is used for

   procedure C_Set_Struct (UID : Unique_Id; T : Type_T)
     with Pre => Present (T), Inline;
   --  Indicate that the previous calls to C_Set_Field_Info for SID
   --  were for LLVM struct type T.

   procedure C_Set_Entity  (V : Value_T; E : Entity_Id)
     with Pre => Present (V), Inline;
   --  Indicate that E is related to V, either the object that V represents
   --  or the GNAT type of V.
   procedure C_Set_Entity  (T : Type_T; TE : Type_Kind_Id)
     with Pre => Present (T), Inline;
   --  Indicate that E is the entity corresponding to T

   procedure C_Set_Parameter (UID : Unique_Id; Idx : Nat; Entity : Entity_Id);
   --  Give the entity corresponding to parameter Idx of the function that
   --  will be denoted by UID

   procedure C_Set_Elab_Proc (V : Value_T; For_Body : Boolean)
     with Pre => Present (V);
   --  Indicate that V is an elab proc and which one it is

   procedure C_Set_Function (UID : Unique_Id; V : Value_T)
     with Pre => Present (V);
   --  Indicate that the previous calls to Set_Parameter_Info for UID
   --  were for LLVM value V.

   procedure C_Note_Enum (TE : E_Enumeration_Type_Id);
   --  Indicate that we're processing the declaration of TE, an enumeration
   --  type.

   function C_Create_Annotation (N : N_Pragma_Id) return Nat;
   --  Return the value to eventually pass to Output_Annotation to perform
   --  the operation designated by the pragma N if there is one to perform.
   --  Otherwise, return 0.

   function C_Dont_Add_Inline_Always return Boolean;
   --  Return True if we're emitting C and shouldn't add an Inline_Always
   --  except when explicitly present in the input source.

   procedure C_Address_Taken (V : Value_T)
     with Pre => Present (V);
   --  Indicate that V is a subprogram whose address is being taken

   procedure Discard (B : Boolean) is null;
   --  Used to discard Boolean function results

   function C_Process_Switch (Switch : String) return Boolean;
   --  Switch is a switch passed to GNAT LLVM. If it's a switch meaningful
   --  to CCG, process it and return True.

   function C_Is_Switch (Switch : String) return Boolean;
   --  Switch is a switch passed to GNAT LLVM. If it's a switch meaningful
   --  to CCG, return True.

end CCG;
