------------------------------------------------------------------------------
--                             G N A T - L L V M                            --
--                                                                          --
--                     Copyright (C) 2013-2018, AdaCore                     --
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

with System;

with LLVM.Types; use LLVM.Types;

--  with Interfaces.C;         use Interfaces.C;
--  with Interfaces.C.Strings; use Interfaces.C.Strings;

package GNATLLVM.Wrapper is

   type MD_Builder_T is new System.Address;
   --  Metadata builder type: opaque for us.

   function Create_MDBuilder_In_Context
     (Ctx : LLVM.Types.Context_T) return MD_Builder_T;
   pragma Import (C, Create_MDBuilder_In_Context,
                  "Create_MDBuilder_In_Context");

   function Create_TBAA_Root (MDBld : MD_Builder_T)
     return LLVM.Types.Metadata_T;
   pragma Import (C, Create_TBAA_Root, "Create_TBAA_Root");

   function LLVM_Init_Module (Module : LLVM.Types.Module_T) return Integer;
   pragma Import (C, LLVM_Init_Module, "LLVM_Init_Module");
   --  Initialize the LLVM module.  Returns 0 if it succeeds.

   function LLVM_Write_Module_Internal
     (Module   : LLVM.Types.Module_T;
      Object   : Integer;
      Filename : String) return Integer;
   pragma Import (C, LLVM_Write_Module_Internal, "LLVM_Write_Object");

end GNATLLVM.Wrapper;
