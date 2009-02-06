# -*- coding: utf-8 -*-
#! /usr/bin/env ruby
require 'rubygems'
require 'detector'
require 'fileutils'

def detect_face(file)
  model = '/usr/local/share/opencv/haarcascades/haarcascade_frontalface_alt2.xml'
  Detector::detect(model, file) != [] ? true : false
end

def images(path)
  Dir.glob(File.join(path, "*.jpg"))
end

def move_to_face(path)
  puts File.basename(path)
  FileUtils.mv(path, File.join("face", File.basename(path)))
end

images("image").each do |f|
  move_to_face(f) if detect_face(f)
end

