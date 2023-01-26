import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../../../protobuf/video/sfu/event/events.pb.dart' as sfu_events;
import '../../../../protobuf/video/sfu/models/models.pb.dart' as sfu_models;
import '../../../../protobuf/video/sfu/signal_rpc/signal.pb.dart' as sfu;
import '../../../logger/stream_logger.dart';
import '../../action/call_control_action.dart';
import '../../call_state_manager.dart';
import '../../errors/video_error.dart';
import '../../errors/video_error_composer.dart';
import '../../model/call_cid.dart';
import '../../sfu/data/events/sfu_events.dart';
import '../../sfu/data/models/sfu_model_mapper_extensions.dart';
import '../../sfu/data/models/sfu_track_type.dart';
import '../../sfu/sfu_client.dart';
import '../../sfu/sfu_client_impl.dart';
import '../../sfu/ws/sfu_event_listener.dart';
import '../../sfu/ws/sfu_ws.dart';
import '../../shared_emitter.dart';
import '../../utils/none.dart';
import '../../utils/result.dart';
import '../../utils/subscriptions.dart';
import '../../webrtc/media/constraints/camera_position.dart';
import '../../webrtc/model/rtc_model_mapper_extensions.dart';
import '../../webrtc/model/rtc_tracks_info.dart';
import '../../webrtc/model/rtc_video_dimension.dart';
import '../../webrtc/peer_connection.dart';
import '../../webrtc/peer_type.dart';
import '../../webrtc/rtc_manager.dart';
import '../../webrtc/rtc_manager_factory.dart';
import '../../webrtc/rtc_track.dart';
import 'call_session.dart';
import 'call_session_config.dart';

const _idParticipants = 1;

class CallSessionImpl extends CallSession implements SfuEventListener {
  CallSessionImpl({
    required this.callCid,
    required this.sessionId,
    required this.config,
    required this.stateManager,
  })  : sfuClient = SfuClientImpl(
          baseUrl: config.sfuUrl,
          authToken: config.sfuToken,
        ),
        sfuWS = SfuWebSocket(
          sfuUrl: config.sfuUrl,
          sessionId: sessionId,
        ),
        rtcManagerFactory = RtcManagerFactory(
          sessionId: sessionId,
          callCid: callCid,
          configuration: config.rtcConfig,
        );

  final _logger = taggedLogger(tag: 'SV:CallSession');
  final _subscriptions = Subscriptions();

  final StreamCallCid callCid;
  @override
  final String sessionId;
  final CallSessionConfig config;
  final CallStateManager stateManager;
  final SfuClientV2 sfuClient;
  final SfuWebSocket sfuWS;
  final RtcManagerFactory rtcManagerFactory;
  RtcManager? rtcManager;

  @override
  SharedEmitter<SfuEventV2> get events => sfuWS.events;

  @override
  Future<Result<None>> start() async {
    try {
      _logger.d(() => '[start] no args');
      sfuWS.addEventListener(this);
      await sfuWS.connect();
      _logger.v(() => '[start] sfu connected');
      final genericSdp = await RtcManager.getGenericSdp();
      _logger.v(() => '[start] genericSdp.len: ${genericSdp.length}');
      sfuWS.send(
        sfu_events.SfuRequest(
          joinRequest: sfu_events.JoinRequest(
            token: config.sfuToken,
            sessionId: sessionId,
            subscriberSdp: genericSdp,
          ),
        ),
      );
      _logger.v(() => '[start] wait for SfuJoinResponseEvent');
      final event = await sfuWS.events.waitFor<SfuJoinResponseEvent>(
        timeLimit: const Duration(seconds: 30),
      );

      _listenParticipantsChanges();

      _logger.v(() => '[start] event: $event');
      final currentUserId = stateManager.state.value.currentUserId;
      final localParticipant = event.callState.participants.firstWhere(
        (it) => it.userId == currentUserId,
      );
      final localTrackId = localParticipant.trackLookupPrefix;
      _logger.v(() => '[start] localTrackId: $localTrackId');
      rtcManager = await rtcManagerFactory.makeRtcManager(
        publisherId: localTrackId,
      )
        ..onPublisherIceCandidate = _onLocalIceCandidate
        ..onSubscriberIceCandidate = _onLocalIceCandidate
        ..onPublisherTrackMuted = _onPublisherTrackMuted
        ..onPublisherNegotiationNeeded = _onPublisherNegotiationNeeded
        ..onSubscriberTrackPublished = _onSubscriberTrackPublished
        ..onSubscriberTrackSubscriptionUpdate =
            _onSubscriberTrackSubscriptionUpdate;

      _logger.v(() => '[start] completed');
      return Result.success(None());
    } catch (e, stk) {
      _logger.e(() => '[start] failed: $e');
      return Result.failure(VideoErrors.compose(e, stk));
    }
  }

  @override
  Future<void> dispose() async {
    _logger.d(() => '[dispose] no args');
    sfuWS.removeEventListener(this);
    await sfuWS.disconnect();
    await rtcManager?.dispose();
    rtcManager = null;
    return await super.dispose();
  }

  @override
  Future<void> updateTrackSize({
    required String userId,
    required SfuTrackType trackType,
    required double width,
    required double height,
  }) async {
    if (trackType != SfuTrackType.video &&
        trackType != SfuTrackType.screenShare) {
      return;
    }
    final participant = stateManager.state.value.callParticipants[userId];
    if (participant == null || participant.isLocal) {
      return;
    }
    final track = sfu.TrackSubscriptionDetails(
      userId: userId,
      sessionId: participant.sessionId,
      trackType: trackType.toDTO(),
      dimension: sfu_models.VideoDimension(
        width: width.toInt(),
        height: height.toInt(),
      ),
    );

    await sfuClient.updateSubscriptions(
      sfu.UpdateSubscriptionsRequest(
        sessionId: sessionId,
        tracks: [track],
      ),
    );
  }

  @override
  RtcTrack? getTrack(String userId, SfuTrackType trackType) {
    final participantState = stateManager.state.value.callParticipants[userId];
    if (participantState == null) {
      return null;
    }
    final trackSid = '${participantState.trackId}:$trackType';
    return rtcManager?.getTrack(trackSid);
  }

  @override
  List<RtcTrack> getTracks(String userId) {
    final participantState = stateManager.state.value.callParticipants[userId];
    if (participantState == null) {
      return List.empty();
    }
    return [...?rtcManager?.getTracks(participantState.trackId)];
  }

  @override
  Future<Result<None>> apply(SessionControlAction action) async {
    if (action is SetCameraEnabled) {
      return _onSetCameraEnabled(action.enabled);
    } else if (action is SetMicrophoneEnabled) {
      return _onSetMicrophoneEnabled(action.enabled);
    } else if (action is SetScreenShareEnabled) {
      return _onSetScreenShareEnabled(action.enabled);
    } else if (action is SetCameraPosition) {
      return _onSetCameraPosition(action.cameraPosition);
    }
    return Result.error('Action not supported: $action');
  }

  @override
  Future<void> onSfuError(VideoError error) async {
    _logger.e(() => '[onSfuError] error: $error');
    // TODO: implement onError
  }

  @override
  Future<void> onSfuEvent(SfuEventV2 event) async {
    _logger.v(() => '[onSfuEvent] event: $event');
    await stateManager.onSfuEvent(event);
    if (event is SfuSubscriberOfferEvent) {
      await _onSubscriberOffer(event);
    } else if (event is SfuIceTrickleEvent) {
      await _onRemoteIceCandidate(event);
    }
  }

  void _listenParticipantsChanges() {
    _subscriptions.add(
      _idParticipants,
      stateManager.state.listen((state) {
        for (var participant in state.callParticipants.values) {
          // TODO do we need this?
        }
      }),
    );
  }

  Future<void> _onSubscriberOffer(SfuSubscriberOfferEvent event) async {
    final offerSdp = event.sdp;
    _logger.i(() => '[onSfuSubscriberOfferEvent] event: $event');
    final answerSdp = await rtcManager?.onSubscriberOffer(offerSdp);
    if (answerSdp == null) return;

    await sfuClient.sendAnswer(
      sfu.SendAnswerRequest(
        sdp: answerSdp,
        peerType: sfu_models.PeerType.PEER_TYPE_SUBSCRIBER,
      ),
    );
  }

  void _onPublisherTrackMuted(RtcLocalTrack track, bool muted) {
    _logger.d(() => '[onPublisherTrackMuted] track: $track');

    sfuClient.updateMuteState(
      sfu.UpdateMuteStatesRequest(
        sessionId: sessionId,
        muteStates: [
          sfu.TrackMuteState(
            trackType: track.trackType.toDTO(),
            muted: muted,
          )
        ],
      ),
    );
  }

  Future<void> _onRemoteIceCandidate(SfuIceTrickleEvent event) async {
    _logger.d(() => '[onRemoteIceCandidate] event: $event');
    rtcManager?.onRemoteIceCandidate(
      peerType: event.peerType,
      iceCandidate: event.iceCandidate,
    );
  }

  void _onLocalIceCandidate(
    StreamPeerConnection pc,
    rtc.RTCIceCandidate candidate,
  ) {
    _logger.d(
      () => '[onLocalIceCandidate] type: ${pc.type}, candidate: $candidate',
    );

    final encodedIceCandidate = json.encode(candidate.toMap());
    final peerType = pc.type == StreamPeerType.publisher
        ? sfu_models.PeerType.PEER_TYPE_PUBLISHER_UNSPECIFIED
        : sfu_models.PeerType.PEER_TYPE_SUBSCRIBER;

    sfuClient.sendIceCandidate(
      sfu_models.ICETrickle(
        peerType: peerType,
        sessionId: sessionId,
        iceCandidate: encodedIceCandidate,
      ),
    );
  }

  Future<void> _onPublisherNegotiationNeeded(StreamPeerConnection pc) async {
    _logger.d(
      () => '[onPubNegotiationNeeded] type: ${pc.type}',
    );

    final offer = await pc.createOffer();
    if (offer is! Success<rtc.RTCSessionDescription>) return;

    final tracksInfo = rtcManager?.getPublisherTrackInfos();
    if (tracksInfo == null) return;

    _logger.v(() => '[onPubNegotiationNeeded] tracksInfo: $tracksInfo');

    final pubResult = await sfuClient.setPublisher(
      sfu.SetPublisherRequest(
        sdp: offer.data.sdp,
        tracks: tracksInfo.toDTO(),
      ),
    );
    if (pubResult is! Success<sfu.SetPublisherResponse>) {
      _logger.w(
        () => '[onPubNegotiationNeeded] #setPublisher; failed: $pubResult',
      );
      return;
    }
    final ansResult = await pc.setRemoteAnswer(pubResult.data.sdp);
    if (ansResult is! Success<void>) {
      _logger.w(
        () => '[onPubNegotiationNeeded] #setRemoteAnswer; failed: $ansResult',
      );
    }
  }

  Future<void> _onSubscriberTrackPublished(
    StreamPeerConnection pc,
    RtcRemoteTrack remoteTrack,
  ) async {
    _logger.d(
      () => '[onSubscriberTrackPublished] remoteTrack: $remoteTrack',
    );
    stateManager.onRtcRemoteTrackPublished(
      remoteTrack.trackId,
      remoteTrack.trackType,
    );
  }

  Future<void> _onSubscriberTrackSubscriptionUpdate({
    required sfu.TrackSubscriptionDetails track,
    required bool subscribe,
  }) async {
    final participants = stateManager.state.value.callParticipants;
    final subscribedTracks = <String, sfu.TrackSubscriptionDetails>{};
    for (final participant in [...participants.values]) {
      // skip local participant
      if (participant.isLocal) continue;

      final tracks = getTracks(participant.trackId);
      for (final track in tracks) {
        final detail = sfu.TrackSubscriptionDetails(
          userId: participant.userId,
          sessionId: participant.sessionId,
          trackType: track.trackType.toDTO(),
          dimension: track.videoDimension?.toDTO(),
        );

        subscribedTracks[detail.trackDetailId] = detail;
      }
    }

    if (subscribe) {
      subscribedTracks[track.trackDetailId] = track;
    } else {
      subscribedTracks.remove(track.trackDetailId);
    }

    await sfuClient.updateSubscriptions(
      sfu.UpdateSubscriptionsRequest(
        sessionId: sessionId,
        tracks: subscribedTracks.values,
      ),
    );
  }

  Future<Result<None>> _onSetCameraEnabled(bool enabled) async {
    final track = await rtcManager?.setCameraEnabled(enabled: enabled);
    if (track == null) {
      return Result.error('Unable to enable/disable camera, Track not found');
    }

    return Result.success(None());
  }

  Future<Result<None>> _onSetMicrophoneEnabled(bool enabled) async {
    final track = await rtcManager?.setMicrophoneEnabled(enabled: enabled);
    if (track == null) {
      return Result.error(
        'Unable to enable/disable microphone, Track not found',
      );
    }

    return Result.success(None());
  }

  Future<Result<None>> _onSetScreenShareEnabled(bool enabled) async {
    final track = await rtcManager?.setScreenShareEnabled(enabled: enabled);
    if (track == null) {
      return Result.error(
        'Unable to enable/disable screen-share, Track not found',
      );
    }

    return Result.success(None());
  }

  Future<Result<None>> _onSetCameraPosition(CameraPosition position) async {
    final track = await rtcManager?.setCameraPosition(cameraPosition: position);
    if (track == null) {
      return Result.error('Unable to set camera position, Track not found');
    }

    return Result.success(None());
  }
}

extension RtcTracksInfoMapper on List<RtcTrackInfo> {
  List<sfu_models.TrackInfo> toDTO() {
    return map((info) {
      return sfu_models.TrackInfo(
        trackId: info.trackId,
        trackType: info.trackType?.toDTO(),
        mid: info.mid,
        layers: info.layers?.map((layer) {
          return sfu_models.VideoLayer(
            rid: layer.rid,
            videoDimension: sfu_models.VideoDimension(
              width: layer.videoDimension?.width,
              height: layer.videoDimension?.height,
            ),
            bitrate: layer.bitrate,
          );
        }),
      );
    }).toList();
  }
}

extension on sfu.TrackSubscriptionDetails {
  /// Returns a unique string to identify this detail from the other details.
  String get trackDetailId {
    return '$userId-$sessionId-$trackType';
  }
}
