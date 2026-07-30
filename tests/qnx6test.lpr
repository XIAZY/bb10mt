program qnx6test;

{$mode objfpc}{$H+}

uses
  Classes,
  consoletestrunner,
  fpcunittestinsight,
  qnx6.device.tests,
  qnx6.blockmgr.tests,
  qnx6.inodemgr.tests,
  qnx6.tests,
  jsonparser;

type

  { TMyTestRunner }

  TMyTestRunner = class(TTestRunner)
  protected
    // override the protected methods of TTestRunner to customize its behavior
  end;

var
  Application: TMyTestRunner;

begin
  if IsTestInsightListening() then
    RunRegisteredTests('', '')
  else
  begin
    DefaultRunAllTests := True;
    DefaultFormat := fPlain;
    Application := TMyTestRunner.Create(nil);
    Application.Initialize;
    Application.Title := 'FPCUnit Console test runner';
    Application.Run;
    Application.Free;
  end;
end.
