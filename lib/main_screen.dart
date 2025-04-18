import 'dart:convert';

import 'package:ai_assistant/openai_server.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  String emphemeralKey = "";
  RTCPeerConnection? peerConnection;
  MediaStream? localStream;
  RTCDataChannel? dataChannel;

  // to play audio
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  bool isOngoingConversation = false;
  String transcript = "";

  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    requestPermissions();
  }

  void requestPermissions() async {
    await Permission.microphone.request();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Ai Assistant with Flutter WebRTC"),
      ),
      body: Center(
        child: SizedBox(
          width: 480,
          child: Column(
            children: [
              (transcript.isNotEmpty && isOngoingConversation)
                  ? SizedBox(
                      width: double.infinity,
                      child: Text("AI: $transcript"),
                    )
                  : const SizedBox(),
              Expanded(
                child: Container(
                  width: double.infinity,
                  alignment: Alignment.center,
                  child: (isLoading)
                      ? const CircularProgressIndicator()
                      : Container(
                          padding: const EdgeInsets.all(24),
                          child: (!isOngoingConversation)
                              ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text("Click Button To Start"),
                                  IconButton(
                                      onPressed: () {
                                        startWebRtcSession();
                                      },
                                      icon: Container(
                                        decoration: const BoxDecoration(
                                            color: Colors.green,
                                            shape: BoxShape.circle),
                                        padding: const EdgeInsets.all(16),
                                        child: const Icon(
                                          Icons.call,
                                          color: Colors.white,
                                          size: 30,
                                        ),
                                      ),
                                    ),
                                ],
                              )
                              : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text("Speak freely"),
                                  IconButton(
                                      onPressed: () {
                                        stopWebRtcConnection();
                                        setState(() {
                                          transcript = "";
                                        });
                                      },
                                      icon: Container(
                                        decoration: const BoxDecoration(
                                            color: Colors.red,
                                            shape: BoxShape.circle),
                                        padding: const EdgeInsets.all(16),
                                        child: const Icon(
                                          Icons.call_end,
                                          color: Colors.white,
                                          size: 30,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> startWebRtcSession() async {
    print("Starting WebRTC Session");
    try {
      stopWebRtcConnection();
      setState(() {
        isLoading = true;
      });
      //Get the emphemral key from OPEN AI
      emphemeralKey = await OpenAIService.getEphemeralToken();
      print("Key Generated: $emphemeralKey");

      //Creating configurations
      final configs = {
        'iceServers': [
          {
            'urls': [
              'stun:stun1.1.google.com:19302',
              'stun:stun2.1.google.com:19302',
            ]
          }
        ],
        'sdpSemantics': 'unified-plan',
        'enableDtlsSrtp': true
      };
      peerConnection = await createPeerConnection(configs);
      if (peerConnection == null) {
        throw Exception("Failed to create peer connection");
      } else {
        setState(() {
          isOngoingConversation = true;
        });
      }
      peerConnection?.onIceCandidate = (candidate) async {
        print("Got the ICE Candidate: ${candidate.candidate ?? ""}");
        if (candidate.candidate != null && peerConnection != null) {
          try {
            await peerConnection!.addCandidate(candidate);
          } catch (e) {
            print("Error adding candidate to the peer connection: $e");
          }
        }
      };

      // Track The Audio
      peerConnection?.onTrack = (RTCTrackEvent event) {
        debugPrint(">> onTrack: ${event.track.kind}");
        if (event.track.kind == 'audio' || event.track.kind == 'video') {
          _remoteRenderer.srcObject = event.streams.first; // Playing audio
        }
      };

      peerConnection?.onConnectionState = (state) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          stopWebRtcConnection();
        }
      };
      final mediaConfigs = {
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGrainControl': true,
        },
        'video': false
      };
      localStream = await navigator.mediaDevices.getUserMedia(mediaConfigs);
      if (peerConnection != null &&
          peerConnection?.connectionState !=
              RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        localStream?.getTracks().forEach((track) {
          peerConnection?.addTrack(track, localStream!);
        });
      }
      //
      // creating a data channel
      RTCDataChannelInit dataChannelInit = RTCDataChannelInit()
        ..ordered = true
        ..maxRetransmits = 30
        ..protocol = 'sctp'
        ..negotiated = false;

      dataChannel = await peerConnection?.createDataChannel(
          "oai-events", dataChannelInit);
      if (dataChannel != null) {
        setupDataChannel();

        // // Send the initial greeting message
        // _dataChannel!.send(RTCDataChannelMessage(json
        //     .encode({'type': 'text', 'text': 'Hi! How are you today?'})));
      }
      //
      final offerOptions = {
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
        'voiceActivityDetection': true,
      };
      RTCSessionDescription? offer;
      offer = await peerConnection?.createOffer(offerOptions);

      await peerConnection?.setLocalDescription(offer!);

      // Send offer to OpenAI's realtime API
      const baseUrl = 'https://api.openai.com/v1/realtime';
      const model = 'gpt-4o-realtime-preview-2024-12-17';

      // Create request with body first
      var request = http.Request('POST', Uri.parse('$baseUrl?model=$model'));
      request.body = offer?.sdp?.replaceAll('\r\n', '\n') ?? '';

      // Then set the headers
      request.headers.addAll({
        'Authorization': 'Bearer $emphemeralKey',
        'Content-Type': 'application/sdp',
        'Accept': 'application/sdp',
      });

      String sdpResponse;
      try {
        // Send the request and get the response
        final response = await http.Client().send(request);
        sdpResponse = await response.stream.bytesToString();

        if (response.statusCode != 200 && response.statusCode != 201) {
          print('Response body: $sdpResponse');
          throw Exception(
              'Failed to get SDP answer: ${response.statusCode} - $sdpResponse');
        }
      } catch (e) {
        print('Error sending offer to OpenAI: $e');
        throw Exception('Failed to send offer to OpenAI: $e');
      }

      print('Received SDP answer from OpenAI: $sdpResponse');

      if (peerConnection != null &&
          peerConnection?.connectionState !=
              RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        try {
          // Set remote description with answer from OpenAI
          final answer = RTCSessionDescription(
            sdpResponse,
            'answer',
          );
          await peerConnection?.setRemoteDescription(answer);
          print('Remote description set - WebRTC connection established');

          // Send a test message after a short delay
          // await Future.delayed(const Duration(seconds: 1));
          // Attach real-time connection state listener
          peerConnection?.onConnectionState =
              (RTCPeerConnectionState? state) async {
            print('Real-time Connection State: $state');

            // Update the app's logic/UI in response to the state
            if (state != null) {
              switch (state) {
                case RTCPeerConnectionState.RTCPeerConnectionStateNew:
                  print('State: New');
                  break;
                case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
                  print('State: Connecting');
                  break;
                case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
                  print('State: Connected');
                  await Future.delayed(const Duration(seconds: 1));

                  setState(() {
                    isLoading = false;
                  });

                  // Send the initial greeting message
                  break;
                case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
                  print('State: Disconnected');
                  break;
                case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
                  print('State: Failed');
                  break;
                case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
                  print('State: Closed');
                  break;
                default:
                  print('Unknown state');
              }
            }
          };
        } catch (e) {}
      }
    } catch (e) {}
  }

  void setupDataChannel() {
    dataChannel?.onMessage = (message) {
      try {
        final data = json.decode(message.text);
        handleOpenAIStream(data);

        print('\n==================== OpenAI Response ====================');
        print('Raw response data: $data');

        // Handle different types of messages from OpenAI
        if (data['type'] == 'conversation.item.text') {
          // addMessage(data['text'], false);

          print('OpenAI Response (Text): ${data['text']}');
        } else if (data['type'] == 'conversation.item.summary') {
          print('OpenAI Response (Summary): ${data['summary']}');
        } else if (data['type'] == 'conversation.item.error') {
          print('OpenAI Response (Error): ${data['error']}');
        } else if (data['type'] == 'conversation.item.create') {
          print('OpenAI Response (Create Item):');
          if (data['item'] != null) {
            if (data['item']['content'] != null &&
                data['item']['content'] is List) {
              for (var content in data['item']['content']) {
                if (content['type'] == 'text' && content['text'] != null) {
                  print('Message: ${content['text']}');
                }
              }
            }
            // Handle direct text in item
            if (data['item']['text'] != null) {
              print('Direct Message: ${data['item']['text']}');
            }
          }
        } else if (data['content'] != null && data['content'] is List) {
          print('OpenAI Response (Content Array):');
          // Handle direct content array
          for (var content in data['content']) {
            if (content['type'] == 'text' && content['text'] != null) {
              print('Content Message: ${content['text']}');
            }
          }
        } else if (data['type'] == "response.audio_transcript.done") {
          print("Response form Api: " + data['transcript']);
        }
        print('======================================================\n');
      } catch (e) {
        print('Error processing OpenAI message: $e');
      }
    };
  }

  void stopWebRtcConnection() async {
    if (dataChannel != null) {
      await dataChannel?.close();
      dataChannel = null;
    }
    if (localStream != null) {
      localStream?.getTracks().forEach((track) => track.stop());
      localStream = null;
    }
    if (peerConnection != null) {
      await peerConnection?.close();
      peerConnection = null;
    }
    setState(() {
      isOngoingConversation = false;
    });

    print("WEB RTc Connection terminated successfully");
  }

  void handleOpenAIStream(Map<String, dynamic> data) {
    final type = data['type'];

    debugPrint("type: $type");

    if (type == 'response.audio') {
      // NOT RECEIVE response.audio if using WebRTC, use WebSocket
      // playAudioFromBase64(data['audio']);
    } else if (type == 'input_audio_buffer.speech_started') {
      setState(() {
        transcript = "";
      });
    } else if (type == 'response.audio_transcript.delta') {
      setState(() {
        transcript += data['delta'];
      });
    }
  }
}
