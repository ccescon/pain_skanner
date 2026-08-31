import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:audioplayers/audioplayers.dart';
import 'package:printing/printing.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path_provider/path_provider.dart';

// Marker IDs
const int idTopLeft = 99;
const int idTopRight = 123;
const int idBottomRight = 432;
const int idBottomLeft = 567;

// Target fixed size (scaled from 2304x3072 to maintain 3:4 aspect ratio)
const int targetWidth = 768;
const int targetHeight = 1024;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  final firstCamera = cameras.first;

  runApp(
    MaterialApp(
      theme: ThemeData.dark(),
      home: TakePictureScreen(
        camera: firstCamera,
      ),
    ),
  );
}

class TakePictureScreen extends StatefulWidget {
  const TakePictureScreen({
    super.key,
    required this.camera,
  });

  final CameraDescription camera;

  @override
  TakePictureScreenState createState() => TakePictureScreenState();
}

class TakePictureScreenState extends State<TakePictureScreen> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isDetecting = false;
  bool _markersVisible = false;
  bool _isCapturing = false;
  String _status = "Point at the 4 corner markers (ArUco)";

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.high,
      enableAudio: false,
    );
    _initializeControllerFuture = _controller.initialize().then((_) {
      _startDetectionLoop();
    });
  }

  void _startDetectionLoop() {
    _controller.startImageStream((CameraImage image) async {
      if (_isDetecting || _isCapturing) return;
      _isDetecting = true;

      try {
        final found = await _detectMarkersInFrame(image);
        if (mounted && found != _markersVisible) {
          setState(() {
            _markersVisible = found;
            _status = found ? "Sheet detected! Tap to capture." : "Point at the 4 corner markers (ArUco)";
          });
        }
      } catch (e) {
        debugPrint("Loop error: $e");
      } finally {
        _isDetecting = false;
      }
    });
  }

  Future<bool> _detectMarkersInFrame(CameraImage image) async {
    cv.VecU8? vec;
    cv.Mat? mat;
    try {
      final yPlane = image.planes[0];
      vec = cv.VecU8.fromList(yPlane.bytes);
      mat = cv.Mat.fromVec(vec,
          rows: image.height, cols: image.width, type: cv.MatType.CV_8UC1);

      final dictionary = cv.ArucoDictionary.predefined(cv.PredefinedDictionaryType.DICT_4X4_1000);
      final parameters = cv.ArucoDetectorParameters.empty();
      final detector = cv.ArucoDetector.create(dictionary, parameters);

      final (_, ids, _) = detector.detectMarkers(mat);

      if (ids.length >= 4) {
        final List<int> foundIds = [];
        for (int i = 0; i < ids.length; i++) {
          foundIds.add(ids[i]);
        }
        return foundIds.contains(idTopLeft) &&
            foundIds.contains(idTopRight) &&
            foundIds.contains(idBottomRight) &&
            foundIds.contains(idBottomLeft);
      }
    } catch (e) {
      debugPrint("Detect error: $e");
    } finally {
      vec?.dispose();
      mat?.dispose();
    }
    return false;
  }

  Future<void> _takePicture() async {
    if (_isCapturing) return;
    setState(() {
      _isCapturing = true;
      _status = "Capturing...";
    });

    try {
      // Play shutter sound
      await _audioPlayer.play(AssetSource('shutter.mp3'));
      
      await _controller.stopImageStream();
      final picture = await _controller.takePicture();

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ProcessingScreen(
            imagePath: picture.path,
          ),
        ),
      );

      setState(() {
        _isCapturing = false;
        _markersVisible = false;
        _status = "Point at the 4 corner markers (ArUco)";
      });
      _startDetectionLoop();
    } catch (e) {
      debugPrint("Capture error: $e");
      setState(() {
        _isCapturing = false;
      });
    }
  }

  Future<void> _downloadPdf() async {
    try {
      final byteData = await rootBundle.load('assets/bodycharts.pdf');
      final bytes = byteData.buffer.asUint8List();
      
      await Printing.sharePdf(bytes: bytes, filename: 'bodycharts.pdf');
    } catch (e) {
      debugPrint("Download error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error downloading PDF: $e")),
        );
      }
    }
  }

  @override
  void dispose() {
    if (_controller.value.isStreamingImages) {
      _controller.stopImageStream();
    }
    _controller.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chart Scan')),
      body: Stack(
        children: [
          FutureBuilder<void>(
            future: _initializeControllerFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.done) {
                return CameraPreview(_controller);
              } else {
                return const Center(child: CircularProgressIndicator());
              }
            },
          ),
          if (!_markersVisible && !_isCapturing)
            Positioned(
              top: 20,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: 180,
                  height: 45,
                  child: ElevatedButton.icon(
                    onPressed: _downloadPdf,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text("Download BCs"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent.withOpacity(0.8),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.only(bottom: 120),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _status,
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),
          ),
          if (_markersVisible && !_isCapturing)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 30),
                child: FloatingActionButton.large(
                  onPressed: _takePicture,
                  backgroundColor: Colors.green,
                  child: const Icon(Icons.camera_alt, size: 40),
                ),
              ),
            ),
          if (_isCapturing)
            const Center(
              child: CircularProgressIndicator(color: Colors.green, strokeWidth: 6),
            ),
        ],
      ),
    );
  }
}

class ProcessingScreen extends StatefulWidget {
  final String imagePath;

  const ProcessingScreen({super.key, required this.imagePath});

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  String? processedImagePath;
  int? redPixelCount;
  double? redPercentage;
  String? identifiedModelName;
  bool processing = true;
  String error = "";

  @override
  void initState() {
    super.initState();
    _processImage();
  }

  Future<void> _processImage() async {
    cv.Mat? mat;
    cv.Mat? warped;
    cv.Mat? mask;
    try {
      mat = cv.imread(widget.imagePath);

      final dictionary = cv.ArucoDictionary.predefined(cv.PredefinedDictionaryType.DICT_4X4_1000);
      final parameters = cv.ArucoDetectorParameters.empty();
      final detector = cv.ArucoDetector.create(dictionary, parameters);

      final (corners, ids, _) = detector.detectMarkers(mat);

      if (ids.length < 4) {
        throw Exception("Insufficient markers. Ensure all 4 corner ArUco markers are visible.");
      }

      Map<int, cv.Point2f> markerMap = {};
      for (int i = 0; i < ids.length; i++) {
        final id = ids[i];
        final markerCorners = corners[i];
        if (id == idTopLeft) {
          markerMap[id] = markerCorners[0];
        } else if (id == idTopRight) {
          markerMap[id] = markerCorners[1];
        } else if (id == idBottomRight) {
          markerMap[id] = markerCorners[2];
        } else if (id == idBottomLeft) {
          markerMap[id] = markerCorners[3];
        }
      }

      if (markerMap.length < 4 ||
          !markerMap.containsKey(idTopLeft) || !markerMap.containsKey(idTopRight) ||
          !markerMap.containsKey(idBottomRight) || !markerMap.containsKey(idBottomLeft)) {
        throw Exception("Required IDs are missing.");
      }

      final srcPoints = cv.VecPoint2f.fromList([
        markerMap[idTopLeft]!,
        markerMap[idTopRight]!,
        markerMap[idBottomRight]!,
        markerMap[idBottomLeft]!,
      ]);

      final dstPoints = cv.VecPoint2f.fromList([
        cv.Point2f(0, 0),
        cv.Point2f(targetWidth.toDouble(), 0),
        cv.Point2f(targetWidth.toDouble(), targetHeight.toDouble()),
        cv.Point2f(0, targetHeight.toDouble()),
      ]);

      final m = cv.getPerspectiveTransform2f(srcPoints, dstPoints);
      warped = cv.warpPerspective(mat, m, (targetWidth, targetHeight));

      // --- Identification Logic ---
      final modelId = await _identifyBodyChart(warped);
      identifiedModelName = modelId;

      // --- Load Mask ---
      int totalGoodPixels = targetWidth * targetHeight;
      final maskName = modelId.replaceAll('_paper', '_mask');
      try {
        final maskData = await rootBundle.load('assets/$maskName.png');
        final maskBuffer = maskData.buffer.asUint8List();
        final maskOrig = cv.imdecode(maskBuffer, cv.IMREAD_GRAYSCALE);
        mask = cv.resize(maskOrig, (targetWidth, targetHeight));
        
        // Calcoliamo l'area "buona" (pixel neri = 0)
        // countNonZero restituisce i pixel bianchi (255)
        int whitePixels = cv.countNonZero(mask);
        totalGoodPixels = (targetWidth * targetHeight) - whitePixels;
        
        maskOrig.dispose();
      } catch (e) {
        debugPrint("Warning: Mask $maskName not found. Count will not be filtered.");
      }

      // --- Red Pixel Count & Highlight with Mask ---
      int count = 0;
      final highlightColor = cv.Vec3b(255, 255, 0); // Ciano
      
      for (int y = 0; y < warped.rows; y++) {
        for (int x = 0; x < warped.cols; x++) {
          // Se la maschera esiste, controlla se il pixel è "buono" (nero = 0)
          if (mask != null) {
            final maskValue = mask.at<int>(y, x);
            if (maskValue != 0) continue; // Salta se è bianco (fuori)
          }

          final pixel = warped.at<cv.Vec3b>(y, x);
          final b = pixel.val1;
          final g = pixel.val2;
          final r = pixel.val3;

          final maxRGB = max(r, max(g, b));
          final minRGB = min(r, min(g, b));

          final chroma = maxRGB - minRGB;

          if (chroma > 40) {
            // Soglia rosso: R > 150 e R > G*1.5 e R > B*1.5
            // if (r > 150 && r > g * 1.5 && r > b * 1.5) {
            count++;
            warped.setVec<cv.Vec3b>(y, x, highlightColor);
          }
        }
      }

      final tempDir = await getTemporaryDirectory();
      final outPath = "${tempDir.path}/warped_${DateTime.now().millisecondsSinceEpoch}.png";
      cv.imwrite(outPath, warped);

      setState(() {
        processedImagePath = outPath;
        redPixelCount = count;
        redPercentage = (count / totalGoodPixels) * 100;
        processing = false;
      });
    } catch (e) {
      setState(() {
        error = e.toString();
        processing = false;
      });
    } finally {
      mat?.dispose();
      mask?.dispose();
      // warped will be saved and can be disposed later or kept if needed. 
      // Actually imwrite saves it, so we can dispose.
      warped?.dispose();
    }
  }

  Future<String> _identifyBodyChart(cv.Mat warped) async {
    final models = [
      'male_dorsal_paper',
      'male_ventral_paper',
      'female_dorsal_paper',
      'female_ventral_paper'
    ];

    final redMask = cv.inRangebyScalar(warped, cv.Scalar(0, 0, 150, 0), cv.Scalar(150, 150, 255, 0));
    final cleanWarped = warped.clone();
    cleanWarped.setTo(cv.Scalar(255, 255, 255, 0), mask: redMask);

    final grayWarped = cv.cvtColor(cleanWarped, cv.COLOR_BGR2GRAY);
    final blurred = cv.gaussianBlur(grayWarped, (5, 5), 0);
    final binaryWarped = cv.adaptiveThreshold(blurred, 255, cv.ADAPTIVE_THRESH_GAUSSIAN_C, cv.THRESH_BINARY_INV, 11, 2);

    final kernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
    final dilatedWarped = cv.dilate(binaryWarped, kernel);

    String bestModel = "male_dorsal_paper";
    int minDiff = 2147483647;

    for (var modelName in models) {
      try {
        final byteData = await rootBundle.load('assets/$modelName.png');
        final buffer = byteData.buffer.asUint8List();
        final templateOrig = cv.imdecode(buffer, cv.IMREAD_GRAYSCALE);
        final template = cv.resize(templateOrig, (targetWidth, targetHeight));
        final (_, binaryTemplate) = cv.threshold(template, 200, 255, cv.THRESH_BINARY_INV);
        final dilatedTemplate = cv.dilate(binaryTemplate, kernel);

        final diff = cv.absDiff(dilatedWarped, dilatedTemplate);
        final diffPixels = cv.countNonZero(diff);

        if (diffPixels < minDiff) {
          minDiff = diffPixels;
          bestModel = modelName;
        }

        templateOrig.dispose();
        template.dispose();
        binaryTemplate.dispose();
        dilatedTemplate.dispose();
        diff.dispose();
      } catch (e) {
        debugPrint("Error loading template $modelName: $e");
      }
    }

    redMask.dispose();
    cleanWarped.dispose();
    grayWarped.dispose();
    blurred.dispose();
    binaryWarped.dispose();
    dilatedWarped.dispose();
    kernel.dispose();

    return bestModel;
  }

  String _formatModelName(String? raw) {
    if (raw == null) return "Unknown";
    return raw.replaceAll('_paper', '').replaceAll('_', ' ').toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Processing Result')),
      body: processing
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 20),
                  Text("Analyzing and cropping..."),
                ],
              ),
            )
          : error.isNotEmpty
              ? Center(child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.red, size: 60),
                    const SizedBox(height: 10),
                    Text(error, textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text("Retry"))
                  ],
                ))
              : SingleChildScrollView(
                  child: Column(
                    children: [
                      if (processedImagePath != null) Image.file(File(processedImagePath!)),
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            Text(
                              'Model: ${_formatModelName(identifiedModelName)}',
                              style: const TextStyle(fontSize: 18, color: Colors.blueAccent, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Coloured pixels: $redPixelCount',
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                            ),
                            if (redPercentage != null)
                              Text(
                                'Pain area: ${redPercentage!.toStringAsFixed(2)}%',
                                style: const TextStyle(fontSize: 20, color: Colors.orangeAccent, fontWeight: FontWeight.bold),
                              ),
                            const Text(
                              "(Areas outside mask were removed)",
                              style: TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                      ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Back to camera')),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
    );
  }
}
