------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--                             G E T _ T A R G                              --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--          Copyright (C) 1992-2023, Free Software Foundation, Inc.         --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License --
-- for  more details.  You should have  received  a copy of the GNU General --
-- Public License  distributed with GNAT; see file COPYING3.  If not, go to --
-- http://www.gnu.org/licenses for a complete copy of the license.          --
--                                                                          --
------------------------------------------------------------------------------

--  This is the LLVM version of this package
--  ??? Will need to replace hardcoded values by target specific information
--  coming from the LLVM backend for the relevant target.

with LLVM.Target; use LLVM.Target;

with GNATLLVM;         use GNATLLVM;
with GNATLLVM.Codegen; use GNATLLVM.Codegen;

with System.OS_Lib; use System.OS_Lib;

with GNAT.Directory_Operations; use GNAT.Directory_Operations;

package body Get_Targ is

   -----------------------
   -- Get_Bits_Per_Unit --
   -----------------------

   function Get_Bits_Per_Unit return Pos is
   begin
      return 8;
   end Get_Bits_Per_Unit;

   -----------------------
   -- Get_Bits_Per_Word --
   -----------------------

   function Get_Bits_Per_Word return Pos is
   begin
      return Pos (Target_C_Types.Register_Size);
   end Get_Bits_Per_Word;

   -------------------
   -- Get_Char_Size --
   -------------------

   function Get_Char_Size return Pos is
   begin
      return Pos (Target_C_Types.Char_Size);
   end Get_Char_Size;

   ----------------------
   -- Get_Wchar_T_Size --
   ----------------------

   function Get_Wchar_T_Size return Pos is
   begin
      return Pos (Target_C_Types.Wchar_T_Size);
   end Get_Wchar_T_Size;

   --------------------
   -- Get_Short_Size --
   --------------------

   function Get_Short_Size return Pos is
   begin
      return Pos (Target_C_Types.Short_Size);
   end Get_Short_Size;

   ------------------
   -- Get_Int_Size --
   ------------------

   function Get_Int_Size return Pos is
   begin
      return Pos (Target_C_Types.Int_Size);
   end Get_Int_Size;

   -------------------
   -- Get_Long_Size --
   -------------------

   function Get_Long_Size return Pos is
   begin
      return Pos (Target_C_Types.Long_Size);
   end Get_Long_Size;

   ------------------------
   -- Get_Long_Long_Size --
   ------------------------

   function Get_Long_Long_Size return Pos is
   begin
      return Pos (Target_C_Types.Long_Long_Size);
   end Get_Long_Long_Size;

   -----------------------------
   -- Get_Long_Long_Long_Size --
   -----------------------------

   function Get_Long_Long_Long_Size return Pos is
   begin
      return Pos (Target_C_Types.Long_Long_Long_Size);
   end Get_Long_Long_Long_Size;

   ----------------------
   -- Get_Pointer_Size --
   ----------------------

   function Get_Pointer_Size return Pos is
   begin
      return Pos (Target_C_Types.Pointer_Size);
   end Get_Pointer_Size;

   ---------------------------
   -- Get_Maximum_Alignment --
   ---------------------------

   function Get_Maximum_Alignment return Pos is
   begin
      return Pos (Target_C_Types.Maximum_Alignment);
   end Get_Maximum_Alignment;

   ------------------------------------
   -- Get_System_Allocator_Alignment --
   ------------------------------------

   function Get_System_Allocator_Alignment return Nat is
   begin
      return 16;
   end Get_System_Allocator_Alignment;

   ------------------------
   -- Get_Float_Words_BE --
   ------------------------

   function Get_Float_Words_BE return Nat is
   begin
      return (if Byte_Order (Module_Data_Layout) = Big_Endian then 1 else 0);
   end Get_Float_Words_BE;

   ------------------
   -- Get_Words_BE --
   ------------------

   function Get_Words_BE return Nat is
   begin
      return (if Byte_Order (Module_Data_Layout) = Big_Endian then 1 else 0);
   end Get_Words_BE;

   ------------------
   -- Get_Bytes_BE --
   ------------------

   function Get_Bytes_BE return Nat is
   begin
      return (if Byte_Order (Module_Data_Layout) = Big_Endian then 1 else 0);
   end Get_Bytes_BE;

   -----------------
   -- Get_Bits_BE --
   -----------------

   function Get_Bits_BE return Nat is
   begin
      return (if Byte_Order (Module_Data_Layout) = Big_Endian then 1 else 0);
   end Get_Bits_BE;

   ---------------------
   -- Get_Short_Enums --
   ---------------------

   function Get_Short_Enums return Int is
   begin
      return (if Short_Enums then 1 else 0);
   end Get_Short_Enums;

   --------------------------
   -- Get_Strict_Alignment --
   --------------------------

   function Get_Strict_Alignment return Nat is
   begin
      return 0;
   end Get_Strict_Alignment;

   --------------------------------
   -- Get_Double_Float_Alignment --
   --------------------------------

   function Get_Double_Float_Alignment return Nat is
   begin
      return 0;
   end Get_Double_Float_Alignment;

   ---------------------------------
   -- Get_Double_Scalar_Alignment --
   ---------------------------------

   function Get_Double_Scalar_Alignment return Nat is
   begin
      return 0;
   end Get_Double_Scalar_Alignment;

   -----------------------------
   -- Register_Back_End_Types --
   -----------------------------

   procedure Register_Back_End_Types (Call_Back : Register_Type_Proc) is
      Float_Str       : C_String := (others => ASCII.NUL);
      Double_Str      : C_String := (others => ASCII.NUL);
      Long_Double_Str : C_String := (others => ASCII.NUL);

   begin
      Float_Str (Float_Str'First .. Float_Str'First + 4) := "float";
      Call_Back
        (C_Name => Float_Str, Digs => 6, Complex => False, Count  => 0,
         Float_Rep => IEEE_Binary,
         Precision => 32, Size => 32, Alignment => 32);

      Double_Str (Double_Str'First .. Double_Str'First + 5) := "double";
      Call_Back
        (C_Name    => Double_Str,
         Digs      => 15,
         Complex   => False,
         Count     => 0,
         Float_Rep => IEEE_Binary,
         Precision => 64,
         Size      => 64,
         Alignment => 64);

      Long_Double_Str (Long_Double_Str'First .. Long_Double_Str'First + 10) :=
        "long double";

      --  We can't currently handle floating-point types with more than 80 bits
      --  of precision; in CCG mode, we don't want to use 80-bit double
      --  extended either because the target hardware likely can't handle it.
      if Nat (Target_C_Types.Long_Double_Precision) = 80
        and then not Emit_C
      then
         Call_Back
           (C_Name    => Long_Double_Str,
            Digs      => 18,
            Complex   => False,
            Count     => 0,
            Float_Rep => IEEE_Binary,
            Precision => 80,
            Size      => Integer (Target_C_Types.Long_Double_Size),
            Alignment => Integer (Target_C_Types.Long_Double_Alignment));
      else
         Call_Back
           (C_Name    => Long_Double_Str,
            Digs      => 15,
            Complex   => False,
            Count     => 0,
            Float_Rep => IEEE_Binary,
            Precision => 64,
            Size      => 64,
            Alignment => 64);
      end if;
   end Register_Back_End_Types;

   ------------------------------
   -- Get_Back_End_Config_File --
   ------------------------------

   function Get_Back_End_Config_File return String_Ptr is

      function Exec_Name return String;
      --  Return name of the current executable (from argv[0])

      function Get_Target_File (Dir : String) return String_Ptr;
      --  Return Dir & "target.atp" if found, null otherwise

      ---------------
      -- Exec_Name --
      ---------------

      function Exec_Name return String is
         type Arg_Array is array (Nat) of Big_String_Ptr;
         type Arg_Array_Ptr is access all Arg_Array;

         gnat_argv : Arg_Array_Ptr;
         pragma Import (C, gnat_argv);

      begin
         for J in 1 .. Natural'Last loop
            if gnat_argv (0) (J) = ASCII.NUL then
               return gnat_argv (0) (1 .. J - 1);
            end if;
         end loop;

         raise Program_Error;
      end Exec_Name;

      ---------------------
      -- Get_Target_File --
      ---------------------

      function Get_Target_File (Dir : String) return String_Ptr is
         F : constant String := Dir & "target.atp";
      begin
         if Is_Regular_File (F) then
            return new String'(F);
         else
            return null;
         end if;
      end Get_Target_File;

      Exec : constant String := Exec_Name;

   --  Start of processing for Get_Back_End_Config_File

   begin
      --  Ensure we've done initialization of LLVM values, including scanning
      --  the command line. Then return the filename.

      Initialize_GNAT_LLVM;
      if Is_Absolute_Path (Exec) then
         return Get_Target_File (Dir_Name (Exec));
      else
         return Get_Target_File (Dir_Name (Locate_Exec_On_Path (Exec).all));
      end if;
   end Get_Back_End_Config_File;

end Get_Targ;
