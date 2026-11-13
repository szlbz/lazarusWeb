{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit lwserver;

{$warn 5023 off : no warning about unused units}
interface

uses
  lwapp, lwwriter, lwsession, lwdispatch, lwhttp, lwws, lwupload, lwajax, 
  lwchart, lwconfig, lwdbgrid, lwdbnav, lwhyper, lwlogin, lwpanel, lwreport, 
  lwrlog, lwui, lwweb, lwwebsocket, lwabout, LazarusPackageIntf;

implementation

procedure Register;
begin
end;

initialization
  RegisterPackage('lwserver', @Register);
end.
