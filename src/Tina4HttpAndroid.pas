unit Tina4HttpAndroid;

{ Android HTTP backend for Tina4Http — uses java.net.HttpURLConnection on a
  worker thread, so HTTPS gets the platform's native TLS (system trust store,
  OS security updates) with NO OpenSSL shipped. This is the fix for the Android
  SSL grief: we never link a crypto library, we call the OS.

  Flow: the Pascal backend's Send calls up to Java (com.tina4.pascal.Http.send)
  via JNI; Java runs the request on a thread and calls back the native
  nativeHttpResult, which hands the response to Tina4Http.HttpDeliver. The UI
  loop drains it with HttpPump (the shell calls that each frame). }

{$mode delphi}{$H+}

interface

uses
  jni, Tina4Http;

{ Install as the process HTTP backend. Pass the JavaVM (cached in JNI_OnLoad). }
procedure InstallAndroidHttp(VM: PJavaVM);
{ Called from the JNI result callback: build a response and queue it. }
procedure AndroidHttpResult(Id, Status: Integer; const Body, Error: string);

implementation

uses SysUtils;

var
  GVM: PJavaVM = nil;
  GHttpCls: jclass = nil;      // cached com.tina4.pascal.Http (global ref)
  GSend: jmethodID = nil;      // static send(int, String×4)

type
  TAndroidHttpBackend = class(TTina4HttpBackend)
  public
    procedure Send(const Req: TTina4HttpRequest); override;
  end;

{ get a JNIEnv for the current thread (attaching it if necessary) }
function CurrentEnv: PJNIEnv;
var res: jint;
begin
  Result := nil;
  if GVM = nil then Exit;
  res := GVM^^.GetEnv(GVM, @Result, JNI_VERSION_1_6);
  if res <> JNI_OK then
    if GVM^^.AttachCurrentThread(GVM, @Result, nil) <> JNI_OK then Result := nil;
end;

procedure TAndroidHttpBackend.Send(const Req: TTina4HttpRequest);
var
  env: PJNIEnv; cls: jclass;
  a: array[0..4] of jvalue;
  jMethod, jUrl, jBody, jCtype: jstring;
begin
  env := CurrentEnv;
  if env = nil then
  begin
    AndroidHttpResult(Req.Id, 0, '', 'no JNI env');
    Exit;
  end;
  if GHttpCls = nil then
  begin
    cls := env^.FindClass(env, 'com/tina4/pascal/Http');
    if cls = nil then begin AndroidHttpResult(Req.Id, 0, '', 'Http class missing'); Exit; end;
    GHttpCls := env^.NewGlobalRef(env, cls);
    GSend := env^.GetStaticMethodID(env, GHttpCls, 'send',
      '(ILjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V');
  end;
  jMethod := env^.NewStringUTF(env, PAnsiChar(Req.Method));
  jUrl    := env^.NewStringUTF(env, PAnsiChar(Req.Url));
  jBody   := env^.NewStringUTF(env, PAnsiChar(Req.Body));
  jCtype  := env^.NewStringUTF(env, PAnsiChar(Req.ContentType));
  a[0].i := Req.Id; a[1].l := jMethod; a[2].l := jUrl; a[3].l := jBody; a[4].l := jCtype;
  env^.CallStaticVoidMethodA(env, GHttpCls, GSend, @a[0]);
  env^.DeleteLocalRef(env, jMethod); env^.DeleteLocalRef(env, jUrl);
  env^.DeleteLocalRef(env, jBody);   env^.DeleteLocalRef(env, jCtype);
end;

procedure InstallAndroidHttp(VM: PJavaVM);
begin
  GVM := VM;
  SetHttpBackend(TAndroidHttpBackend.Create);
end;

procedure AndroidHttpResult(Id, Status: Integer; const Body, Error: string);
var r: TTina4HttpResponse;
begin
  r.Id := Id; r.Url := ''; r.Status := Status; r.Body := Body;
  r.ContentType := ''; r.Error := Error;
  HttpDeliver(r);
end;

end.
