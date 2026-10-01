import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'app_palette.dart';
import 'comments_page.dart';
import 'edit_bio_page.dart';
import 'messages_page.dart';
import 'profile_photo_adjust_page.dart';
import 'social_avatar.dart';
import 'social_service.dart';

class SocialProfilePage extends StatefulWidget {
  const SocialProfilePage(
      {super.key, required this.name, required this.isOwnProfile, this.userId});

  final String name;
  final bool isOwnProfile;
  final String? userId;

  @override
  State<SocialProfilePage> createState() => _SocialProfilePageState();
}

class _SocialProfilePageState extends State<SocialProfilePage> {
  static const _red = Color(0xFFCA000A);
  bool _marketOpen = false;
  bool _isFollowing = false;
  bool _isFollowedBy = false;
  bool _followRequestPending = false;
  bool _followBusy = false;
  bool _messageBusy = false;
  bool _uploading = false;
  String? _resolvedUserId;
  String? _avatarUrl;
  String? _coverUrl;
  // Controls are placed over the cover image, so this is deliberately based
  // on cover pixels rather than the app's selected light/dark theme.
  bool _coverTopIsLight = false;
  SocialProfileDetails? _profileDetails;
  late final Stream<List<SocialPost>> _postsStream;

  String? get _profileUserId => widget.isOwnProfile
      ? FirebaseAuth.instance.currentUser?.uid
      : (_resolvedUserId ?? widget.userId);

  @override
  void initState() {
    super.initState();
    _postsStream = SocialService.instance.posts();
    if (!widget.isOwnProfile && widget.userId == null) {
      _resolveUserId();
    } else {
      _loadFollowStatus();
      _loadPhotos();
      _loadProfileDetails();
    }
  }

  Future<void> _resolveUserId() async {
    try {
      final results = await SocialService.instance.searchProfiles(widget.name);
      if (results.isNotEmpty && mounted) {
        setState(() => _resolvedUserId = results.first.id);
        _loadFollowStatus();
        _loadPhotos();
        _loadProfileDetails();
      }
    } catch (_) {}
  }

  Future<void> _loadProfileDetails() async {
    final id = _profileUserId;
    if (id == null) return;
    try {
      final details = await SocialService.instance.profileDetails(id);
      if (mounted) setState(() => _profileDetails = details);
    } catch (_) {
      // Profile content remains usable while a stats migration is pending.
    }
  }

  Future<void> _editBio() async {
    final details = _profileDetails;
    final bio = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => EditBioPage(initialBio: details?.bio ?? ''),
      ),
    );
    if (bio != null && mounted) {
      setState(() => _profileDetails = (details ??
              const SocialProfileDetails(bio: '', followers: 0, following: 0))
          .copyWith(bio: bio));
    }
  }

  Future<void> _loadPhotos() async {
    final id = _profileUserId;
    if (id == null) return;
    try {
      final data = await SocialService.instance.profilePhotos(id);
      if (mounted)
        setState(() {
          _avatarUrl = data?['avatar_url'] as String?;
          _coverUrl = data?['cover_url'] as String?;
        });
      final coverUrl = data?['cover_url'] as String?;
      if (coverUrl != null && coverUrl.isNotEmpty) {
        _readCoverTopBrightness(coverUrl);
      }
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not load profile photos.')));
    }
  }

  Future<void> _readCoverTopBrightness(String url) async {
    try {
      final bytes = (await NetworkAssetBundle(Uri.parse(url)).load(url))
          .buffer
          .asUint8List();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (pixels == null) return;
      // Sample the upper third where the navigation buttons sit. Sampling a
      // small grid avoids a full, expensive image scan on large cover photos.
      final width = image.width;
      final height = image.height;
      var total = 0.0;
      var count = 0;
      final stepX = (width / 16).clamp(1, width).round().toInt();
      final stepY = ((height * .34) / 8).clamp(1, height).round().toInt();
      for (var y = 0; y < height * .34; y += stepY) {
        for (var x = 0; x < width; x += stepX) {
          final offset = (y * width + x) * 4;
          final red = pixels.getUint8(offset) / 255;
          final green = pixels.getUint8(offset + 1) / 255;
          final blue = pixels.getUint8(offset + 2) / 255;
          total += .2126 * red + .7152 * green + .0722 * blue;
          count++;
        }
      }
      final isLight = count > 0 && total / count > .57;
      if (mounted && _coverUrl == url) {
        setState(() => _coverTopIsLight = isLight);
      }
    } catch (_) {
      // Keep the safe light-on-dark default if an image cannot be sampled.
    }
  }

  Future<void> _choosePhoto(bool cover) async {
    if (_uploading || !widget.isOwnProfile) return;
    setState(() => _uploading = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
          withData: true);
      if (!mounted || picked == null) return;
      if (cover) {
        await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => ProfilePhotoAdjustPage(
              file: picked.files.single,
              cover: true,
              profileName: widget.name,
              profileAvatarUrl: _avatarUrl,
              onCoverConfirmed: _uploadCoverFromEditor,
            ),
          ),
        );
        return;
      }
      final adjusted = await Navigator.push<PlatformFile>(
        context,
        MaterialPageRoute(
          builder: (_) => ProfilePhotoAdjustPage(
            file: picked.files.single,
            cover: false,
          ),
        ),
      );
      if (!mounted || adjusted == null) return;
      final url = await SocialService.instance
          .uploadProfilePhoto(adjusted, cover: false);
      if (mounted)
        setState(() {
          _avatarUrl = url;
        });
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save photo: $error')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<bool> _uploadCoverFromEditor(PlatformFile photo) async {
    try {
      final url =
          await SocialService.instance.uploadProfilePhoto(photo, cover: true);
      if (!mounted) return false;
      setState(() => _coverUrl = url);
      _readCoverTopBrightness(url);
      return true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not upload cover photo: $error')),
        );
      }
      return false;
    }
  }

  Future<void> _showPhotoUploadOptions() async {
    if (_uploading || !widget.isOwnProfile) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppPalette.surface(context),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              'Update your photos',
              style: TextStyle(
                color: AppPalette.text(sheetContext),
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            _photoUploadOption(
              sheetContext,
              icon: Icons.add_a_photo_outlined,
              title: 'Upload profile photo',
              subtitle: 'Shown in your profile circle and posts.',
              onTap: () {
                Navigator.pop(sheetContext);
                _choosePhoto(false);
              },
            ),
            const SizedBox(height: 8),
            _photoUploadOption(
              sheetContext,
              icon: Icons.panorama_outlined,
              title: 'Upload cover photo',
              subtitle: 'Shown across the top of your profile.',
              onTap: () {
                Navigator.pop(sheetContext);
                _choosePhoto(true);
              },
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _loadFollowStatus() async {
    final userId = _profileUserId;
    if (widget.isOwnProfile || userId == null) return;
    try {
      final results = await Future.wait([
        SocialService.instance.isFollowing(userId),
        SocialService.instance.isFollowedBy(userId),
        SocialService.instance.hasPendingFollowRequest(userId),
      ]);
      if (mounted) {
        setState(() {
          _isFollowing = results[0];
          _isFollowedBy = results[1];
          _followRequestPending = results[2];
        });
      }
    } catch (_) {
      // The profile still works if follow requests have not been configured.
    }
  }

  Future<void> _openDirectMessage() async {
    if (_messageBusy) return;
    setState(() => _messageBusy = true);
    try {
      var userId = _profileUserId;
      if (userId == null && !widget.isOwnProfile) {
        try {
          final results =
              await SocialService.instance.searchProfiles(widget.name);
          if (results.isNotEmpty) {
            userId = results.first.id;
            if (mounted) setState(() => _resolvedUserId = userId);
          }
        } catch (_) {}
      }

      final targetId = userId;
      if (targetId == null) {
        if (!mounted) return;
        Navigator.push(
            context, MaterialPageRoute(builder: (_) => const MessagesPage()));
        return;
      }

      final conversationId =
          await SocialService.instance.startDirectConversation(targetId);
      if (!mounted) return;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ChatPage(
                  conversation: ConversationSummary(
                      id: conversationId,
                      otherUserId: targetId,
                      name: widget.name,
                      lastMessage: '',
                      updatedAt: null,
                      unread: false,
                      avatarUrl: _avatarUrl))));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open conversation: $error')));
      }
    } finally {
      if (mounted) {
        setState(() => _messageBusy = false);
      }
    }
  }

  void _messageFromProfile() {
    _openDirectMessage();
  }

  Future<void> _updateFollow() async {
    final userId = _profileUserId;
    if (userId == null || _followBusy) return;
    setState(() => _followBusy = true);
    try {
      if (_isFollowing) {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('Unfollow this account?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Keep following')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Unfollow'))
                    ]));
        if (confirmed != true) return;
        await SocialService.instance.unfollow(userId);
      } else if (_followRequestPending) {
        await SocialService.instance.cancelFollowRequest(userId);
      } else {
        await SocialService.instance.sendFollowRequest(userId);
      }
      await Future.wait([_loadFollowStatus(), _loadProfileDetails()]);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update follow: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        top: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _profileHero(context)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(32, 16, 32, 120),
              sliver: SliverToBoxAdapter(
                child: Column(
                  children: [
                    _tabs(context),
                    const SizedBox(height: 28),
                    if (_marketOpen) _market(context) else _posts(context),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _profileHero(BuildContext context) {
    final initial = widget.name.isNotEmpty
        ? widget.name.substring(0, 1).toUpperCase()
        : '?';
    return Column(
      children: [
        SizedBox(
          height: 310,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: _coverUrl == null
                    ? Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              _red,
                              _red.withValues(alpha: .86),
                              AppPalette.page(context),
                            ],
                            stops: const [0, .48, 1],
                          ),
                        ),
                        child: Icon(
                          Icons.person_rounded,
                          size: 155,
                          color: Colors.white.withValues(alpha: .28),
                        ),
                      )
                    : Image.network(
                        _coverUrl!,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        filterQuality: FilterQuality.high,
                        errorBuilder: (_, __, ___) => Container(
                          color: _red,
                          child: Icon(
                            Icons.person_rounded,
                            size: 155,
                            color: Colors.white.withValues(alpha: .28),
                          ),
                        ),
                      ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppPalette.page(context).withValues(alpha: 0),
                        AppPalette.page(context).withValues(alpha: .08),
                        AppPalette.page(context).withValues(alpha: .48),
                        AppPalette.page(context),
                      ],
                      stops: const [0, .42, .78, 1],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 34,
                left: 5,
                right: 17,
                child: Row(children: [
                  _topIcon(context, Icons.arrow_back_ios_new_rounded,
                      () => Navigator.pop(context),
                      outlined: true),
                  const Spacer(),
                  _topIcon(context, Icons.send_rounded, _openDirectMessage),
                  const SizedBox(width: 8),
                  _topIcon(context, Icons.notifications_rounded, () {},
                      outlined: true),
                  const SizedBox(width: 8),
                  _topIcon(context, Icons.search_rounded, () {},
                      outlined: true),
                ]),
              ),
              Positioned(
                bottom: -12,
                left: 0,
                right: 0,
                child: Center(
                  child: SizedBox(
                    width: 130,
                    height: 130,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          top: 5,
                          left: 5,
                          child: Container(
                            width: 120,
                            height: 120,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppPalette.surface(context),
                              border: Border.all(color: Colors.white, width: 3),
                            ),
                            alignment: Alignment.center,
                            child: _avatarUrl != null
                                ? ClipOval(
                                    child: Image.network(
                                      _avatarUrl!,
                                      width: 114,
                                      height: 114,
                                      fit: BoxFit.cover,
                                      filterQuality: FilterQuality.high,
                                      errorBuilder: (_, __, ___) =>
                                          Text(initial),
                                    ),
                                  )
                                : Text(
                                    initial,
                                    style: const TextStyle(
                                      fontSize: 46,
                                      fontWeight: FontWeight.w800,
                                      color: _red,
                                    ),
                                  ),
                          ),
                        ),
                        if (widget.isOwnProfile)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: _profilePhotoAddButton(context),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (_uploading)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        Text(widget.name,
            style: TextStyle(
                color: AppPalette.text(context),
                fontSize: 22,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text('@${widget.name.toLowerCase().replaceAll(' ', '')}',
            style: const TextStyle(
                color: _red, fontSize: 11, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _stat(context, '${_profileDetails?.followers ?? 0}', 'Followers'),
          Container(
              height: 31,
              width: 1,
              margin: const EdgeInsets.symmetric(horizontal: 25),
              color: AppPalette.border(context)),
          _stat(context, '${_profileDetails?.following ?? 0}', 'Following'),
        ]),
        const SizedBox(height: 18),
        Text(
            _profileDetails?.bio.isNotEmpty == true
                ? _profileDetails!.bio
                : 'Music is better when it is shared.',
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppPalette.text(context), fontSize: 12.5)),
        const SizedBox(height: 7),
        InkWell(
          onTap: widget.isOwnProfile ? _editBio : null,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            child: Text(widget.isOwnProfile ? 'Edit bio' : 'Musician',
                style: TextStyle(
                    color: AppPalette.muted(context), fontSize: 10.5)),
          ),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: widget.isOwnProfile
              ? _ownActions(context)
              : _friendAction(context),
        ),
      ],
    );
  }

  Widget _topIcon(BuildContext context, IconData icon, VoidCallback action,
          {bool outlined = false}) =>
      InkWell(
        onTap: action,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
              // Preserve the original visual language (black filled send;
              // white outlined navigation). Only invert a control when its
              // original color would disappear into the cover photo.
              color: outlined
                  ? (_coverTopIsLight
                      ? Colors.black.withValues(alpha: .86)
                      : Colors.transparent)
                  : (_coverTopIsLight
                      ? Colors.black
                      : Colors.white.withValues(alpha: .98)),
              shape: BoxShape.circle,
              border: outlined
                  ? Border.all(
                      color: _coverTopIsLight ? Colors.black : Colors.white)
                  : null),
          child: Icon(icon,
              color: outlined
                  ? Colors.white
                  : (_coverTopIsLight ? Colors.white : Colors.black),
              size: 20),
        ),
      );

  Widget _profilePhotoAddButton(BuildContext context) => Semantics(
        button: true,
        label: 'Update profile or cover photo',
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: _uploading ? null : _showPhotoUploadOptions,
            customBorder: const CircleBorder(),
            child: Ink(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                color: _red,
                shape: BoxShape.circle,
              ),
              child: _uploading
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.add_rounded,
                      color: Colors.white, size: 22),
            ),
          ),
        ),
      );

  Widget _photoUploadOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) =>
      Material(
        color: AppPalette.page(context),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Icon(icon, color: _red),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: AppPalette.text(context),
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            color: AppPalette.muted(context), fontSize: 12)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: AppPalette.muted(context)),
            ]),
          ),
        ),
      );

  Widget _stat(BuildContext context, String value, String label) =>
      Column(children: [
        Text(value,
            style: TextStyle(
                color: AppPalette.text(context),
                fontSize: 14,
                fontWeight: FontWeight.w700)),
        Text(label,
            style: TextStyle(color: AppPalette.text(context), fontSize: 12))
      ]);

  Widget _ownActions(BuildContext context) => Row(children: [
        Expanded(
            child: _button(context, 'Edit profile', Icons.edit_rounded,
                filled: true, onTap: _editBio)),
        const SizedBox(width: 12),
        Expanded(
            child: _button(context, 'Share profile', Icons.share_outlined,
                onTap: () {})),
      ]);

  Widget _friendAction(BuildContext context) {
    final followButton = _button(
      context,
      _isFollowing
          ? 'Following'
          : _followRequestPending
              ? 'Follow request pending'
              : _isFollowedBy
                  ? 'Follow back'
                  : 'Follow',
      _isFollowing
          ? Icons.check_rounded
          : _followRequestPending
              ? Icons.schedule_rounded
              : Icons.person_add_alt_1_rounded,
      filled: !_followRequestPending,
      onTap: _followBusy ? () {} : _updateFollow,
    );
    return Row(children: [
      Expanded(child: followButton),
      const SizedBox(width: 12),
      Expanded(
        child: _button(
          context,
          _messageBusy ? 'Opening...' : 'Message',
          Icons.chat_bubble_outline_rounded,
          onTap: _messageBusy ? () {} : _messageFromProfile,
        ),
      ),
    ]);
  }

  Widget _button(BuildContext context, String label, IconData icon,
      {bool filled = false, required VoidCallback onTap}) {
    return SizedBox(
      height: 40,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
        style: OutlinedButton.styleFrom(
          foregroundColor: filled ? Colors.white : AppPalette.text(context),
          backgroundColor: filled ? _red : Colors.transparent,
          side: BorderSide(
              color: filled ? _red : AppPalette.border(context), width: 1.1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _tabs(BuildContext context) => Row(children: [
        _tab(context, 'All posts', !_marketOpen,
            () => setState(() => _marketOpen = false)),
        const SizedBox(width: 40),
        _tab(context, 'Music market', _marketOpen,
            () => setState(() => _marketOpen = true)),
      ]);

  Widget _tab(BuildContext context, String label, bool active,
          VoidCallback onTap) =>
      InkWell(
          onTap: onTap,
          child: Column(children: [
            Text(label,
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontSize: 15,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Container(
                width: 66, height: 3, color: active ? _red : Colors.transparent)
          ]));

  Widget _posts(BuildContext context) {
    final userId = _profileUserId;
    if (userId == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 34),
        child: Text('This profile is unavailable.',
            style: TextStyle(color: AppPalette.muted(context))),
      );
    }
    return StreamBuilder<List<SocialPost>>(
      stream: _postsStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.only(top: 34),
            child: Text(
              'Could not load posts. Pull down to try again.',
              style: TextStyle(color: AppPalette.muted(context)),
            ),
          );
        }
        if (!snapshot.hasData)
          return const Padding(
              padding: EdgeInsets.only(top: 40),
              child: CircularProgressIndicator());
        final posts =
            snapshot.data!.where((post) => post.authorId == userId).toList();
        if (posts.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(top: 34),
            child: Text(
                widget.isOwnProfile
                    ? 'Your posts will appear here.'
                    : 'No posts yet.',
                style: TextStyle(color: AppPalette.muted(context))),
          );
        }
        return Column(
          children: posts
              .map((post) => Padding(
                    padding: const EdgeInsets.only(bottom: 30),
                    child: _ProfilePost(post: post),
                  ))
              .toList(),
        );
      },
    );
  }

  Widget _market(BuildContext context) {
    final userId = _profileUserId;
    if (userId == null) return const SizedBox.shrink();
    return StreamBuilder<List<MarketplaceListing>>(
      stream: SocialService.instance.marketplaceListings(userId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const CircularProgressIndicator();
        }
        final items = snapshot.data!;
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(top: 28),
            child: Text(
                widget.isOwnProfile
                    ? 'Your marketplace listings will appear here.'
                    : 'No marketplace listings yet.',
                style: TextStyle(color: AppPalette.muted(context))),
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Music',
              style: TextStyle(
                  color: AppPalette.text(context),
                  fontSize: 22,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          GridView.count(
            // Profile listings are a gallery: always keep two compact cards
            // per row instead of expanding them into full-width items.
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 1,
            children: items
                .map((item) => _MarketItem(
                    title: item.title,
                    category: item.category,
                    price: '\$${item.price.toStringAsFixed(2)}',
                    imageUrl: item.coverUrl))
                .toList(),
          ),
        ]);
      },
    );
  }
}

class _ProfilePost extends StatelessWidget {
  const _ProfilePost({required this.post});
  final SocialPost post;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => CommentsPage(post: post)),
        ),
        borderRadius: BorderRadius.circular(26),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            SocialAccountAvatar(
              name: post.authorName,
              imageUrl: post.authorAvatarUrl,
              size: 36,
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(post.authorName,
                      style: TextStyle(
                          color: AppPalette.text(context),
                          fontSize: 15,
                          fontWeight: FontWeight.w800)),
                  Text('Just now',
                      style: TextStyle(
                          color: AppPalette.muted(context), fontSize: 10))
                ])),
            Icon(Icons.more_horiz_rounded, color: AppPalette.text(context))
          ]),
          if (post.body.trim().isNotEmpty &&
              post.media.isEmpty &&
              post.mediaUrl == null) ...[
            const SizedBox(height: 9),
            Text(post.body,
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontSize: 12.5,
                    height: 1.25)),
          ],
          if (post.media.isNotEmpty || post.mediaUrl != null) ...[
            const SizedBox(height: 9),
            _ProfilePostAttachments(post: post),
          ],
          if (post.body.trim().isEmpty &&
              post.media.isEmpty &&
              post.mediaUrl == null)
            Text('Shared an update',
                style: TextStyle(
                    color: AppPalette.muted(context), fontSize: 12.5)),
          const SizedBox(height: 5),
          Row(children: [
            Icon(
                post.isLiked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: post.isLiked
                    ? const Color(0xFFCA000A)
                    : AppPalette.text(context),
                size: 21),
            const SizedBox(width: 5),
            Text('${post.likes}',
                style: TextStyle(color: AppPalette.text(context))),
            const SizedBox(width: 18),
            Icon(Icons.chat_bubble_outline_rounded,
                color: AppPalette.text(context), size: 20),
            const SizedBox(width: 5),
            Text('${post.comments}',
                style: TextStyle(color: AppPalette.text(context)))
          ]),
          if (post.body.trim().isNotEmpty &&
              (post.media.isNotEmpty || post.mediaUrl != null)) ...[
            const SizedBox(height: 4),
            Text(post.body,
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontSize: 12.5,
                    height: 1.25)),
          ],
        ]),
      );
}

class _ProfilePostAttachments extends StatelessWidget {
  const _ProfilePostAttachments({required this.post});

  final SocialPost post;

  @override
  Widget build(BuildContext context) {
    final media = post.media.isNotEmpty
        ? post.media
        : post.mediaUrl == null || post.mediaType == null
            ? const <PostMedia>[]
            : [PostMedia(url: post.mediaUrl!, type: post.mediaType!)];
    return Column(
      children: media
          .map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: item.type == 'image'
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(26),
                      child: AspectRatio(
                        aspectRatio: 1.12,
                        child: Image.network(
                          item.url,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.high,
                          errorBuilder: (_, __, ___) =>
                              _mediaUnavailable(context),
                        ),
                      ),
                    )
                  : _mediaUnavailable(
                      context,
                      icon: item.type == 'audio'
                          ? Icons.audio_file_rounded
                          : Icons.play_circle_outline_rounded,
                      label: item.type == 'audio'
                          ? 'Audio attachment'
                          : 'Video attachment',
                    ),
            ),
          )
          .toList(),
    );
  }

  Widget _mediaUnavailable(
    BuildContext context, {
    IconData icon = Icons.image_not_supported_outlined,
    String label = 'Image unavailable',
  }) =>
      Container(
        height: 110,
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(26),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: AppPalette.muted(context)),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: AppPalette.muted(context))),
        ]),
      );
}

class _MarketItem extends StatelessWidget {
  const _MarketItem(
      {required this.title,
      required this.category,
      required this.price,
      this.imageUrl});
  final String title;
  final String category;
  final String price;
  final String? imageUrl;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          border: Border.all(color: AppPalette.border(context)),
          borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child: Container(
                width: double.infinity,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppPalette.surface(context),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: imageUrl != null && imageUrl!.startsWith('http')
                    ? Image.network(imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(
                            Icons.music_note_rounded,
                            color: AppPalette.muted(context),
                            size: 36))
                    : Icon(Icons.music_note_rounded,
                        color: AppPalette.muted(context), size: 36))),
        const SizedBox(height: 6),
        Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: AppPalette.text(context),
                fontSize: 12,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 1),
        Text(category,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppPalette.muted(context), fontSize: 10)),
        Align(
            alignment: Alignment.centerRight,
            child: Text(price,
                style: const TextStyle(
                    color: _SocialProfilePageState._red,
                    fontSize: 12,
                    fontWeight: FontWeight.w800)))
      ]));
}
