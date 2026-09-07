program t3danim;

{ AnimationMixer — an articulated walker (limb groups pivoting at hips/shoulders)
  driven by a Walk AnimationClip of KeyframeTracks. Rendered as a 2x2 montage at
  four points in the cycle so the swing reads in one still. The deer/ram clips
  animate the same way. Pure software. }

{$mode delphi}{$H+}

uses SysUtils, ThreePascal;

const TW = 380; TH = 240; BW = TW*2; BH = TH*2;
var
  scene: TScene; camera: TPerspectiveCamera; renderer: TWebGLRenderer;
  amb: TAmbientLight; sun: TDirectionalLight;
  floor: TMesh; figure, legL, legR, armL, armR: TGroup;
  clip: TAnimationClip; mixer: TAnimationMixer;
  big: array of Byte;
  f, yy, qx, qy: Integer;

  function Limb(parent: TGroup; const nm: string; px, py, pz, w, h, d: Single; col: LongWord): TGroup;
  var grp: TGroup; m: TMesh;
  begin
    grp := TGroup.Create; grp.Name := nm; grp.Position.SetXYZ(px, py, pz);
    m := TMesh.Create(TBoxGeometry.Create(w, h, d), TMeshStandardMaterial.Create(col));
    m.Position.SetXYZ(0, -h/2, 0);                  // hang below the pivot
    grp.Add(m); parent.Add(grp); Result := grp;
  end;
  procedure Track(const nm: string; tgt: TTrackTarget; a, b2, c: TV3);
  var t: TKeyframeTrack;
  begin
    t := TKeyframeTrack.Create(nm, tgt);
    t.AddKey(0, a); t.AddKey(0.5, b2); t.AddKey(1.0, c);
    clip.AddTrack(t);
  end;
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
  scene := TScene.Create; scene.Background.SetHex($0e0f1f);
  camera := TPerspectiveCamera.Create(45, TW/TH, 0.1, 100);
  camera.Position.SetXYZ(2.6, 1.7, 4.4); camera.LookAt(0, 0.95, 0);

  amb := TAmbientLight.Create($ffffff, 0.5); scene.Add(amb);
  sun := TDirectionalLight.Create($fff4cf, 0.8); sun.Position.SetXYZ(4, 8, 5); scene.Add(sun);
  floor := TMesh.Create(TPlaneGeometry.Create(20, 20), TMeshStandardMaterial.Create($16172c));
  floor.Rotation.x := -Pi/2; scene.Add(floor);

  { rig: body + head + 4 limb groups (pivots at hip / shoulder) }
  figure := TGroup.Create; figure.Name := 'figure';
  figure.Add(TMesh.Create(TBoxGeometry.Create(0.5,0.8,0.28), TMeshStandardMaterial.Create($2b41e6)));
  TMesh(figure.Children[0]).Position.SetXYZ(0,1.05,0);
  figure.Add(TMesh.Create(TBoxGeometry.Create(0.34,0.34,0.34), TMeshStandardMaterial.Create($ffd2a0)));
  TMesh(figure.Children[1]).Position.SetXYZ(0,1.62,0);
  legL := Limb(figure, 'legL', -0.14, 0.72, 0, 0.17, 0.72, 0.17, $3a3d55);
  legR := Limb(figure, 'legR',  0.14, 0.72, 0, 0.17, 0.72, 0.17, $3a3d55);
  armL := Limb(figure, 'armL', -0.33, 1.35, 0, 0.13, 0.6,  0.13, $1a2aa8);
  armR := Limb(figure, 'armR',  0.33, 1.35, 0, 0.13, 0.6,  0.13, $1a2aa8);
  scene.Add(figure);

  { Walk clip: legs swing opposite; arms opposite their same-side leg; body bobs }
  clip := TAnimationClip.Create('Walk', 1.0);
  Track('legL', ttRotation, V3( 0.6,0,0), V3(-0.6,0,0), V3( 0.6,0,0));
  Track('legR', ttRotation, V3(-0.6,0,0), V3( 0.6,0,0), V3(-0.6,0,0));
  Track('armL', ttRotation, V3(-0.5,0,0), V3( 0.5,0,0), V3(-0.5,0,0));
  Track('armR', ttRotation, V3( 0.5,0,0), V3(-0.5,0,0), V3( 0.5,0,0));
  Track('figure', ttPosition, V3(0,0,0), V3(0,0.02,0), V3(0,0,0));

  mixer := TAnimationMixer.Create(figure); mixer.Play(clip);

  renderer := TWebGLRenderer.Create(TW, TH);
  SetLength(big, BW*BH*4);
  for f := 0 to 3 do
  begin
    mixer.Time := f*0.25; mixer.Apply;             // sample the clip at t = 0, .25, .5, .75
    renderer.Render(scene, camera);
    qx := (f mod 2)*TW; qy := (f div 2)*TH;
    for yy := 0 to TH-1 do
      Move(renderer.Pixels[yy*TW*4], big[((qy+yy)*BW + qx)*4], TW*4);
  end;
  WriteBMP24('/tmp/t3danim.bmp', BW, BH, big);
  WriteLn('rendered walk-cycle montage -> /tmp/t3danim.bmp');
end.
