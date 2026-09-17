unit Tina4NotifyAndroid;

{ Android local notifications: registers the engine's notify handler so
  notify.show('Title','Body') (or an SSE/WebSocket handler calling Tina4Notify)
  posts a real OS notification via the Java Tina4Notify.show(...) using JNI.
  Mirrors Tina4HttpAndroid's native→Java call pattern. }

{$mode delphi}{$H+}

interface

uses jni;

{ Install as the engine's notify handler. Pass the JavaVM (cached in JNI_OnLoad). }
procedure InstallAndroidNotify(VM: PJavaVM);

implementation

uses SysUtils, Tina4RenderBackend;

var
  GVM: PJavaVM = nil;
  GCls: jclass = nil;
  GShow: jmethodID = nil;

procedure AndroidNotify(const Title, Body, Tag: string);
var
  env: PJNIEnv; cls: jclass;
  jT, jB, jG: jstring; a: array[0..2] of jvalue;
begin
  // Fetch the JNIEnv inline (a separate parameterless Env() function got
  // elided by -O2 and env aliased to the first string param — SIGSEGV in
  // FindClass). Keep GetEnv here so env is always a real interface pointer.
  env := nil;
  if GVM = nil then Exit;
  GVM^^.GetEnv(GVM, @env, JNI_VERSION_1_6);
  if env = nil then
    if GVM^^.AttachCurrentThread(GVM, @env, nil) <> JNI_OK then env := nil;
  if env = nil then Exit;
  if GCls = nil then
  begin
    cls := env^.FindClass(env, 'com/tina4/pascal/Tina4Notify');
    if cls = nil then Exit;
    GCls := env^.NewGlobalRef(env, cls);
    GShow := env^.GetStaticMethodID(env, GCls, 'show',
      '(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V');
  end;
  if GShow = nil then Exit;
  jT := env^.NewStringUTF(env, PAnsiChar(Title));
  jB := env^.NewStringUTF(env, PAnsiChar(Body));
  jG := env^.NewStringUTF(env, PAnsiChar(Tag));
  a[0].l := jT; a[1].l := jB; a[2].l := jG;
  env^.CallStaticVoidMethodA(env, GCls, GShow, @a[0]);
  env^.DeleteLocalRef(env, jT);
  env^.DeleteLocalRef(env, jB);
  env^.DeleteLocalRef(env, jG);
end;

procedure InstallAndroidNotify(VM: PJavaVM);
begin
  GVM := VM;
  Tina4SetNotifyHandler(@AndroidNotify);
end;

end.
