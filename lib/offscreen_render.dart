// Offscreen widget rasterisation, transcribed from home_widget 0.9.3
// `HomeWidget.renderFlutterWidget` minus its file-save tail.
//
// This is the exact pipeline the production app ran 8-16 times per background
// task to refresh its home-screen widgets, which is what makes it the right
// workload for this harness: it is the thing that was allocating Impeller
// Vulkan framebuffers inside every short-lived background engine.
//
// The load-bearing line is `repaintBoundary.toImage(...)`. That is
// `OffsetLayer.toImage` -> `ui.Scene.toImage` -> a native snapshot taken on
// the raster thread, which allocates a real VkFramebuffer in THIS engine's
// Impeller Vulkan context. Nothing about the widget tree matters to the bug;
// the framebuffer allocation and its deferred destruction do.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Contrast knob, NOT a fix.
///
/// Left false to match home_widget, which never disposes the images it
/// produces. Flip to true for a contrast run: if the crash stops reproducing
/// with eager disposal, that alone localises the problem to the deferred
/// finalisation path.
const bool disposeImages = false;

/// Renders [widget] offscreen at [logicalSize] / [pixelRatio] and returns PNG
/// bytes.
///
/// Transcribed from home_widget 0.9.3 `renderFlutterWidget`. Everything up to
/// and including `toImage` is that method verbatim in behaviour; only the
/// trailing `saveFile` call is dropped, because writing the PNG to disk is
/// irrelevant to the Vulkan lifecycle under investigation.
Future<Uint8List> renderOffscreen(
  Widget widget, {
  required Size logicalSize,
  required double pixelRatio,
}) async {
  // home_widget dereferences `implicitView!`. A background FlutterEngine
  // created with no attached surface can legitimately have no implicit view,
  // in which case that would throw; fall back to a Picture-based snapshot,
  // which exercises the same raster-thread allocation without a RenderView.
  final ui.FlutterView? view = ui.PlatformDispatcher.instance.implicitView;
  if (view == null) {
    debugPrint(
      '[vk-churn] implicitView NULL - falling back to Picture.toImage',
    );
    return _pictureFallback(logicalSize, pixelRatio);
  }

  final RenderRepaintBoundary repaintBoundary = RenderRepaintBoundary();
  final PipelineOwner pipelineOwner = PipelineOwner();
  final BuildOwner buildOwner = BuildOwner(focusManager: FocusManager());

  final RenderView renderView = RenderView(
    view: view,
    child: RenderPositionedBox(
      alignment: Alignment.center,
      child: repaintBoundary,
    ),
    configuration: ViewConfiguration(
      logicalConstraints: BoxConstraints.tight(logicalSize),
      devicePixelRatio: pixelRatio,
    ),
  );

  pipelineOwner.rootNode = renderView;
  renderView.prepareInitialFrame();

  final RenderObjectToWidgetElement<RenderBox> rootElement =
      RenderObjectToWidgetAdapter<RenderBox>(
        container: repaintBoundary,
        child: Directionality(textDirection: TextDirection.ltr, child: widget),
      ).attachToRenderTree(buildOwner);

  // home_widget runs buildScope twice. Kept for parity: the second pass is
  // what settles anything the first pass dirtied, and dropping it would change
  // how much work lands in the single flushPaint below.
  buildOwner.buildScope(rootElement);
  buildOwner.buildScope(rootElement);
  buildOwner.finalizeTree();

  pipelineOwner.flushLayout();
  pipelineOwner.flushCompositingBits();
  pipelineOwner.flushPaint();

  // The allocation that matters. Crosses to the raster thread and back.
  final ui.Image image = await repaintBoundary.toImage(pixelRatio: pixelRatio);
  final ByteData? byteData = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );

  // PARITY LEAK - home_widget never disposes this image. Undisposed images
  // finalize during engine teardown, the exact window where cached
  // framebuffers get destroyed against a dead VkDevice. Do not 'fix' this.
  if (disposeImages) {
    image.dispose();
  }

  if (byteData == null) {
    throw Exception('Failed to encode widget to PNG');
  }
  return byteData.buffer.asUint8List();
}

/// Surface-free snapshot path, used when the background engine has no implicit
/// view.
///
/// Needs no RenderView, so it cannot hit the `implicitView!` throw. Picture
/// .toImage still rasterises on the raster thread against this engine's
/// Impeller context, so it allocates and releases the same class of Vulkan
/// resources the full pipeline does.
Future<Uint8List> _pictureFallback(Size logicalSize, double pixelRatio) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.scale(pixelRatio);

  final Rect rect = Offset.zero & logicalSize;
  final Paint paint = Paint()
    ..shader = const LinearGradient(
      colors: <Color>[Colors.deepOrange, Colors.indigo],
    ).createShader(rect);
  canvas.drawRRect(
    RRect.fromRectAndRadius(rect.deflate(8), const Radius.circular(24)),
    paint,
  );

  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(
    (logicalSize.width * pixelRatio).ceil(),
    (logicalSize.height * pixelRatio).ceil(),
  );
  final ByteData? byteData = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );

  // The Picture is disposed; the Image deliberately is not, for the same
  // parity reason as above.
  picture.dispose();
  if (disposeImages) {
    image.dispose();
  }

  if (byteData == null) {
    throw Exception('Failed to encode fallback picture to PNG');
  }
  return byteData.buffer.asUint8List();
}
