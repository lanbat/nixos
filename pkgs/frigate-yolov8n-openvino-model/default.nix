# pkgs/frigate-yolov8n-openvino-model/default.nix
#
# YOLOv8n OpenVINO IR model for Frigate's OpenVINO detector.
# Exported from Ultralytics YOLOv8n (640x640, NCHW).
{
  pkgs ? import <nixpkgs> { },
}:

let
  base =
    "https://raw.githubusercontent.com/lucasdevit0/Ultralytics-YOLOv8/main/models/yolov8n_openvino_model";
in
pkgs.runCommand "frigate-yolov8n-openvino-model" { } ''
  mkdir -p $out
  cp ${pkgs.fetchurl {
    url = "${base}/yolov8n.xml";
    hash = "sha256-a6iD7XgcSo9IyTyvFYU9G+699mDwL0/XVY/CyzN5szY=";
  }} $out/yolov8n.xml
  cp ${pkgs.fetchurl {
    url = "${base}/yolov8n.bin";
    hash = "sha256-FSBR7ofGmndAoszRL3wPUbwcDO2vtRSkMjnxMnMD0Hs=";
  }} $out/yolov8n.bin
  cp ${pkgs.fetchurl {
    url = "${base}/metadata.yaml";
    hash = "sha256-xzJsbDwVr4rPcCn/DtAU3zkIFbf5SfpD2FZRzzV8j+4=";
  }} $out/metadata.yaml
''
