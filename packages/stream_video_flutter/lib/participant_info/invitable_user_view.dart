import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:stream_video/stream_video.dart';
import 'package:stream_video_flutter/participant_info/theme/invitable_user_theme.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

/// {@template onInvitableUserTap}
/// The action to perform when the user is tapped.
/// {@endtemplate}
typedef OnInvitableUserTap = void Function(UserInfo);

class StreamInvitableUserView extends StatelessWidget {
  const StreamInvitableUserView(
      {super.key,
      required this.user,
      required this.selected,
      required this.selectedIcon,
      this.invitableUserTheme,
      this.onInvitableUserTap});

  final UserInfo user;
  final bool selected;
  final IconData selectedIcon;

  /// Theme for the invitable user list.
  final StreamInvitableUserTheme? invitableUserTheme;

  /// {@macro onInvitableUserTap}
  final OnInvitableUserTap? onInvitableUserTap;

  @override
  Widget build(BuildContext context) {
    final streamChatTheme = StreamVideoTheme.of(context);
    final invitableUserTheme = this.invitableUserTheme ??
        streamChatTheme.invitableUserListTheme.invitableUserTheme;
    final avatarTheme =
        invitableUserTheme.avatarTheme ?? streamChatTheme.avatarTheme;
    return InkWell(
      onTap: () => onInvitableUserTap?.call(user),
      child: Container(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            StreamUserAvatar(
              user: user,
              avatarTheme: avatarTheme,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(
                  user.name,
                  style: invitableUserTheme.usernameTextStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            Visibility(
              visible: selected,
              child: Container(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  selectedIcon,
                  color: invitableUserTheme.selectedIconColor,
                  size: 32,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
