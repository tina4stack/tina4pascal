program sheep_snapshot;

{ Headless verifier for the sheep — renders the walk cycle as a 2x2 montage so
  the animation reads in one still (the macOS app renders the same scene live). }

{$mode delphi}{$H+}

uses SysUtils, ThreePascal, RamModel;

const TW = 400; TH = 320; BW = TW*2; BH = TH*2;
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer;
  amb: TAmbientLight; sun: TDirectionalLight;
  floor: TMesh; sheep: TGroup; clip: TAnimationClip; mixer: TAnimationMixer;
  big: array of Byte; f, yy, qx, qy: Integer;

  procedure WriteBMP24(const fn: string; w, h: Integer; const rgba: array of Byte);
  var fl: file; hdr: array[0..53] of Byte; row, col, i, rowsize, pad, datasize: Integer; bt: Byte;
  begin
    rowsize:=w*3; pad:=(4-(rowsize mod 4)) mod 4; datasize:=(rowsize+pad)*h;
    FillChar(hdr,SizeOf(hdr),0); hdr[0]:=$42; hdr[1]:=$4D; i:=54+datasize; Move(i,hdr[2],4);
    i:=54; Move(i,hdr[10],4); i:=40; Move(i,hdr[14],4);
    Move(w,hdr[18],4); Move(h,hdr[22],4); hdr[26]:=1; hdr[28]:=24; Move(datasize,hdr[34],4);
    AssignFile(fl,fn); Rewrite(fl,1); BlockWrite(fl,hdr,54);
    for row:=h-1 downto 0 do
    begin
      for col:=0 to w-1 do begin i:=(row*w+col)*4;
        bt:=rgba[i+2]; BlockWrite(fl,bt,1); bt:=rgba[i+1]; BlockWrite(fl,bt,1); bt:=rgba[i+0]; BlockWrite(fl,bt,1); end;
      bt:=0; for col:=1 to pad do BlockWrite(fl,bt,1);
    end;
    CloseFile(fl);
  end;

begin
  scene:=TScene.Create; scene.Background.SetHex($0e0f1f);
  camera:=TPerspectiveCamera.Create(42, TW/TH, 0.05, 100);
  camera.Position.SetXYZ(2.5, 1.35, 2.7); camera.LookAt(0, 0.72, 0.05);

  amb:=TAmbientLight.Create($ffffff, 0.6); scene.Add(amb);
  sun:=TDirectionalLight.Create($fff4cf, 0.8); sun.Position.SetXYZ(4, 8, 5); scene.Add(sun);
  floor:=TMesh.Create(TPlaneGeometry.Create(24, 24), TMeshStandardMaterial.Create($1b7a3a));
  floor.Rotation.x:=-Pi/2; scene.Add(floor);

  sheep:=BuildRam; scene.Add(sheep);
  clip:=RamWalkClip; mixer:=TAnimationMixer.Create(sheep); mixer.Play(clip);

  renderer:=TWebGLRenderer.Create(TW, TH);
  SetLength(big, BW*BH*4);
  for f:=0 to 3 do
  begin
    mixer.Time:=f*0.225; mixer.Apply;
    renderer.Render(scene, camera);
    qx:=(f mod 2)*TW; qy:=(f div 2)*TH;
    for yy:=0 to TH-1 do Move(renderer.Pixels[yy*TW*4], big[((qy+yy)*BW+qx)*4], TW*4);
  end;
  WriteBMP24('/tmp/sheep.bmp', BW, BH, big);
  WriteLn('sheep walk montage -> /tmp/sheep.bmp');
end.
