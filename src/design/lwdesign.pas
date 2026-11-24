{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit lwdesign;

{$warn 5023 off : no warning about unused units}
interface

uses
  lwdsgnregister, lwdsgntplgen, lwdsgntplcore, lwdsgnconvert, lwconvert_core, 
  ulwconvertgui, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('lwdsgnregister', @lwdsgnregister.Register);
  RegisterUnit('lwdsgntplgen', @lwdsgntplgen.Register);
  RegisterUnit('lwdsgnconvert', @lwdsgnconvert.Register);
end;

initialization
  RegisterPackage('lwdesign', @Register);
end.
