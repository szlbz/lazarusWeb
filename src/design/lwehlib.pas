{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit lwehlib;

{$warn 5023 off : no warning about unused units}
interface

uses
  lwdsgnehlib, lwehlibconvert, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('lwdsgnehlib', @lwdsgnehlib.Register);
end;

initialization
  RegisterPackage('lwehlib', @Register);
end.
