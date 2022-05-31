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

with LLVM.Core; use LLVM.Core;

with Atree;  use Atree;
with Errout; use Errout;
with Lib;

with GNATLLVM.Codegen; use GNATLLVM.Codegen;
with GNATLLVM.Wrapper; use GNATLLVM.Wrapper;

with CCG.Environment;  use CCG.Environment;
with CCG.Helper;       use CCG.Helper;
with CCG.Instructions; use CCG.Instructions;
with CCG.Output;       use CCG.Output;
with CCG.Subprograms;  use CCG.Subprograms;
with CCG.Target;       use CCG.Target;
with CCG.Utils;        use CCG.Utils;
with CCG.Write;        use CCG.Write;

package body CCG is

   --  This package and its children generate C code from the LLVM IR
   --  generated by GNAT LLLVM.

   -------------------------
   -- Initialize_C_Output --
   -------------------------

   procedure Initialize_C_Output is
   begin
      --  When emitting C, we don't want to write variable-specific debug
      --  info, just line number information. But we do want to write #line
      --  info if -g was specified. We always want to write location
      --  information into the LLVM IR specified.

      Emit_Full_Debug_Info := False;
      Emit_C_Line          := Emit_Debug_Info;
      Emit_Debug_Info      := True;

      --  If we're to read C parameter values, do so

      if Target_Info_File /= null then
         Read_C_Parameters (Target_Info_File.all);
      end if;

      --  If we're to dump the C parameters, do so

      if Dump_C_Parameters then
         Output_C_Parameters;
      end if;

   end Initialize_C_Output;

   ------------------
   -- Write_C_Code --
   ------------------

   procedure Write_C_Code (Module : Module_T) is
      function Is_Public (V : Value_T) return Boolean;
      --  True if V is publically-visible

      Func : Value_T;
      Glob : Value_T;

      ---------------
      -- Is_Public --
      ---------------

      function Is_Public (V : Value_T) return Boolean is
        (Get_Linkage (V) not in Internal_Linkage | Private_Linkage);

   begin
      Initialize_Writing;

      --  Declare all functions first, since they may be referenced in
      --  globals.

      Func := Get_First_Function (Module);
      while Present (Func) loop
         if not Emit_Header
           or else (Present (Get_First_Basic_Block (Func))
                      and then Is_Public (Func))
         then
            Declare_Subprogram (Func);
         end if;

         Func := Get_Next_Function (Func);
      end loop;

      --  Write out declarations for all globals with initializers if
      --  writing C code and all public globals if writing a header

      Glob := Get_First_Global (Module);
      while Present (Glob) loop
         if Present (Get_Initializer (Glob))
           and then (Is_Public (Glob) or else not Emit_Header)
         then
            Maybe_Decl (Glob);
         end if;

         Glob := Get_Next_Global (Glob);
      end loop;

      --  Process all functions, writing referenced globals and
      --  typedefs on the fly and queueing the rest for later output.

      if not Emit_Header then
         Func := Get_First_Function (Module);
         while Present (Func) loop
            Output_Subprogram (Func);
            Func := Get_Next_Function (Func);
         end loop;
      end if;

      --  Finally, write all the code we generated and finalize the writing
      --  process.

      Write_Subprograms;
      Finalize_Writing;
   end Write_C_Code;

   ----------------------
   -- C_Set_Field_Info --
   ----------------------

   procedure C_Set_Field_Info
     (UID         : Unique_Id;
      Idx         : Nat;
      Name        : Name_Id   := No_Name;
      Entity      : Entity_Id := Empty;
      Is_Padding  : Boolean   := False;
      Is_Bitfield : Boolean   := False) is
   begin
      if Emit_C then
         Set_Field_C_Info (UID, Idx, Name, Entity, Is_Padding, Is_Bitfield);
      end if;
   end C_Set_Field_Info;

   ------------------
   -- C_Set_Struct --
   ------------------

   procedure C_Set_Struct (UID : Unique_Id; T : Type_T) is
   begin
      if Emit_C then
         Set_Struct (UID, T);
      end if;
   end C_Set_Struct;

   ---------------------
   -- C_Set_Parameter --
   ---------------------

   procedure C_Set_Parameter
     (UID : Unique_Id; Idx : Nat; Entity : Entity_Id) is
   begin
      if Emit_C then
         Set_Parameter (UID, Idx, Entity);
      end if;
   end C_Set_Parameter;

   --------------------
   -- C_Set_Function --
   --------------------

   procedure C_Set_Function (UID : Unique_Id; V : Value_T) is
   begin
      if Emit_C then
         Set_Function (UID, V);
      end if;
   end C_Set_Function;

   ------------------
   -- C_Set_Entity --
   ------------------

   procedure C_Set_Entity (V : Value_T; E : Entity_Id) is
   begin
      --  We only want to set this the first time because that will be the
      --  most reliable information. But we also don't need this for a
      --  constants.

      if Emit_C and then not Is_A_Constant_Int (V) and then No (Get_Entity (V))
      then
         Notify_On_Value_Delete (V, Delete_Value_Info'Access);
         Set_Entity (V, E);
      end if;
   end C_Set_Entity;

   ---------------
   -- Error_Msg --
   ---------------

   procedure Error_Msg (Msg : String; V : Value_T) is
   begin
      if Is_A_Instruction (V) or else Is_A_Function (V)
        or else Is_A_Global_Variable (V)
      then
         declare
            File : constant String := Get_Debug_Loc_Filename (V);
            Line : constant String := CCG.Helper.Get_Debug_Loc_Line (V)'Image;
         begin
            if File /= "" then
               Error_Msg_N (Msg & " at " & File & ":" & Line (2 .. Line'Last),
                            Lib.Cunit (Types.Main_Unit));
               return;
            end if;
         end;
      end if;

      Error_Msg_N (Msg, Lib.Cunit (Types.Main_Unit));
   end Error_Msg;

   -------------------------
   -- C_Create_Annotation --
   -------------------------

   function C_Create_Annotation (S : String) return Nat
     renames Create_Annotation;

   ---------------------
   -- C_Set_Parameter --
   ---------------------

   procedure C_Set_Parameter (S : String)
     renames Set_C_Parameter;
end CCG;
