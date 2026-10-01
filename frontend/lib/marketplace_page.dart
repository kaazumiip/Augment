import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_palette.dart';
import 'create_marketplace_listing_page.dart';
import 'morphing_search_bar.dart';
import 'social_service.dart';
import 'marketplace_payment_service.dart';
import 'marketplace_purchases_page.dart';
import 'seller_dashboard_page.dart';
import 'keyboard_aware_sheet.dart';
import 'card_number_validation.dart';

const _marketplaceProducts = [
  _Product('Midnight', 'Music', '\$2.69', 'assets/band.png'),
  _Product('Glance', 'Music', '\$3.59', 'assets/solo.png'),
  _Product(
      'After Hours', 'Music sheet', '\$4.20', 'assets/sheet_music_preview.png'),
  _Product('Moonlight', 'Music', '\$2.99', 'assets/band.png'),
  _Product('City Lights', 'Lyrics', '\$1.99', 'assets/saxophonist.png'),
];

class MarketplacePage extends StatefulWidget {
  const MarketplacePage({Key? key}) : super(key: key);

  @override
  State<MarketplacePage> createState() => _MarketplacePageState();
}

class _MarketplacePageState extends State<MarketplacePage> {
  static const _red = Color(0xFFCA000A);
  static const _font = 'Instrument Sans';

  final _searchController = TextEditingController();
  var _category = 'Music';
  var _cart = <_CartItem>[];
  var _products = <_Product>[];
  StreamSubscription<List<MarketplaceListing>>? _listingsSubscription;

  @override
  void initState() {
    super.initState();
    _listingsSubscription = SocialService.instance.marketplaceFeed().listen(
      (listings) {
        if (mounted) {
          setState(
              () => _products = listings.map(_Product.fromListing).toList());
        }
      },
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _listingsSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final visibleProducts = _products
        .where((product) {
          final matchesTab =
              _category == 'Music' || product.category == _category;
          return matchesTab &&
              (query.isEmpty || product.title.toLowerCase().contains(query));
        })
        .take(3)
        .toList();
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    final ownProducts = currentUserId == null
        ? const <_Product>[]
        : _products
            .where((product) => product.ownerId == currentUserId)
            .toList();

    return ColoredBox(
      color: AppPalette.page(context),
      child: Stack(
        children: [
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    _Header(
                      cartCount:
                          _cart.fold(0, (sum, item) => sum + item.quantity),
                      onCart: _openCart,
                      onSellerDashboard: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SellerDashboardPage()),
                      ),
                      onPurchases: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const MarketplacePurchasesPage()),
                      ),
                      searchController: _searchController,
                      onSearchChanged: (_) => setState(() {}),
                      onOpenSearch: () async {
                        await Navigator.of(context).push(
                          morphSearchRoute(
                            (_) => _MarketplaceSearchPage(products: _products),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 18),
                    const _MarketplaceHero(),
                    const SizedBox(height: 14),
                    _CategoryTabs(
                      selected: _category,
                      onSelected: (value) => setState(() => _category = value),
                    ),
                    const SizedBox(height: 30),
                    Text(
                      'Music',
                      style: TextStyle(
                        fontFamily: _font,
                        color: AppPalette.text(context),
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 14),
                  ]),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 136),
                sliver: visibleProducts.isEmpty
                    ? const SliverToBoxAdapter(child: _NoResults())
                    : SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _productStrip(visibleProducts),
                            const SizedBox(height: 28),
                            Text('Your listings',
                                style: TextStyle(
                                  fontFamily: _font,
                                  color: AppPalette.text(context),
                                  fontSize: 21,
                                  fontWeight: FontWeight.w800,
                                )),
                            const SizedBox(height: 12),
                            ownProducts.isEmpty
                                ? _OwnListingsEmpty(
                                    onCreate: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              const CreateMarketplaceListingPage()),
                                    ),
                                  )
                                : _productStrip(ownProducts),
                          ],
                        ),
                      ),
              ),
            ],
          ),
          Positioned(
            right: 28,
            bottom: 103,
            child: Semantics(
              button: true,
              label: 'Add a listing',
              child: Material(
                color: _red,
                shape: const CircleBorder(),
                elevation: 5,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const CreateMarketplaceListingPage()));
                  },
                  child: const SizedBox(
                    width: 62,
                    height: 62,
                    child:
                        Icon(Icons.add_rounded, color: Colors.white, size: 38),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _addToCart(_Product product) {
    final existing =
        _cart.indexWhere((item) => item.product.title == product.title);
    setState(() {
      if (existing >= 0) {
        _cart[existing].quantity++;
      } else {
        _cart.add(_CartItem(product));
      }
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(existing >= 0
            ? '${product.title} quantity updated in your cart'
            : '${product.title} added to your cart'),
        action: SnackBarAction(label: 'View cart', onPressed: _openCart),
      ));
  }

  Future<void> _openCart() async {
    final cart = await Navigator.of(context).push<List<_CartItem>>(
      MaterialPageRoute(builder: (_) => _CartPage(items: _cart)),
    );
    if (cart != null && mounted) {
      setState(() => _cart = cart);
    }
  }

  Widget _productStrip(List<_Product> products) => SizedBox(
        height: 260,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          itemCount: products.length,
          separatorBuilder: (_, __) => const SizedBox(width: 18),
          itemBuilder: (context, index) => SizedBox(
            width: 214,
            child: _ProductCard(
              product: products[index],
              onTap: () async {
                final product = await Navigator.of(context)
                    .push<_Product>(MaterialPageRoute(
                  builder: (_) => _MarketplaceProductPage(
                    product: products[index],
                  ),
                ));
                if (product != null && mounted) _addToCart(product);
              },
            ),
          ),
        ),
      );
}

class _OwnListingsEmpty extends StatelessWidget {
  const _OwnListingsEmpty({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppPalette.border(context)),
        ),
        child: Row(children: [
          const Icon(Icons.storefront_outlined,
              color: _MarketplacePageState._red),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Your published products will appear here.',
                style:
                    TextStyle(color: AppPalette.muted(context), fontSize: 11)),
          ),
          TextButton(onPressed: onCreate, child: const Text('Create')),
        ]),
      );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.cartCount,
    required this.onCart,
    required this.onSellerDashboard,
    required this.onPurchases,
    required this.searchController,
    required this.onSearchChanged,
    required this.onOpenSearch,
  });
  final int cartCount;
  final VoidCallback onCart;
  final VoidCallback onSellerDashboard;
  final VoidCallback onPurchases;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final Future<void> Function() onOpenSearch;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Stack(children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: LogoBackMorph(tag: 'marketplace-logo-back', showBack: false),
        ),
        Positioned(
          right: 52,
          child: _RoundButton(
            icon: Icons.shopping_cart_outlined,
            outlined: true,
            badge: cartCount,
            onTap: onCart,
          ),
        ),
        Positioned(
          right: 104,
          child: _RoundButton(
            icon: Icons.account_circle_outlined,
            outlined: true,
            onTap: () => _openAccountMenu(context),
          ),
        ),
        Positioned(
          right: 0,
          child: MorphingSearchBar(
            controller: searchController,
            onChanged: onSearchChanged,
            hintText: 'Search music',
            heroTag: 'marketplace-search',
            width: MediaQuery.sizeOf(context).width - 100,
            onOpen: onOpenSearch,
          ),
        ),
      ]),
    );
  }

  Future<void> _openAccountMenu(BuildContext context) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 26),
            decoration: BoxDecoration(
              color: AppPalette.surface(sheetContext),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFCA000A),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Marketplace account',
                    style: TextStyle(
                        color: AppPalette.text(sheetContext),
                        fontSize: 21,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 14),
              _MarketplaceAccountOption(
                icon: Icons.download_done_rounded,
                title: 'My purchases',
                subtitle: 'Download products you have paid for',
                onTap: () {
                  Navigator.pop(sheetContext);
                  onPurchases();
                },
              ),
              const SizedBox(height: 10),
              _MarketplaceAccountOption(
                icon: Icons.storefront_outlined,
                title: 'Seller dashboard',
                subtitle: 'Manage listings, sales and payouts',
                onTap: () {
                  Navigator.pop(sheetContext);
                  onSellerDashboard();
                },
              ),
            ]),
          ),
        ),
      );
}

class _MarketplaceAccountOption extends StatelessWidget {
  const _MarketplaceAccountOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppPalette.page(context),
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: AppPalette.border(context)),
          ),
          child: Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFFCA000A).withValues(alpha: .10),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: const Color(0xFFCA000A)),
            ),
            const SizedBox(width: 12),
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
                            color: AppPalette.muted(context), fontSize: 11)),
                  ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFFCA000A)),
          ]),
        ),
      );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton(
      {required this.icon, this.outlined = false, this.badge = 0, this.onTap});
  final IconData icon;
  final bool outlined;
  final int badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Stack(clipBehavior: Clip.none, children: [
      Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color:
                    outlined ? Colors.transparent : _MarketplacePageState._red,
                shape: BoxShape.circle,
                border: outlined
                    ? Border.all(color: _MarketplacePageState._red)
                    : null),
            child: Icon(icon,
                color: outlined ? _MarketplacePageState._red : Colors.white,
                size: 22),
          ),
        ),
      ),
      if (badge > 0)
        Positioned(
            right: -5,
            top: -5,
            child: Container(
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: const BoxDecoration(
                    color: Colors.black, shape: BoxShape.circle),
                child: Text('$badge',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800)))),
    ]);
  }
}

class _MarketplaceHero extends StatelessWidget {
  const _MarketplaceHero();
  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.width <= 360;
    return SizedBox(
      height: compact ? 320 : 360,
      child: Stack(children: [
        Positioned(
            left: 12,
            top: compact ? 112 : 126,
            child: SizedBox(
                width: compact ? 150 : 300,
                child: Text(
                    compact
                        ? 'Music,\nSheet\nand\nLyric for\neveryone'
                        : 'Music,\nSheet and Lyric\nfor everyone',
                    style: TextStyle(
                        fontFamily: _MarketplacePageState._font,
                        fontSize: compact ? 30 : 40,
                        height: compact ? .84 : 1.0,
                        letterSpacing: 0,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.text(context))))),
        Positioned(
          right: compact ? -24 : 0,
          top: 16,
          child: Image.asset(
            'assets/marketplace_banner.png',
            width: compact ? 280 : 360,
            height: compact ? 240 : 296,
            fit: BoxFit.contain,
            alignment: Alignment.topCenter,
          ),
        ),
      ]),
    );
  }
}

class _CategoryTabs extends StatelessWidget {
  const _CategoryTabs({required this.selected, required this.onSelected});
  final String selected;
  final ValueChanged<String> onSelected;
  @override
  Widget build(BuildContext context) {
    const tabs = ['Music', 'Music sheet', 'Lyrics'];
    final selectedIndex = tabs.indexOf(selected).clamp(0, tabs.length - 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        const style = TextStyle(
          fontFamily: _MarketplacePageState._font,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        );
        final widths = tabs
            .map((tab) => (TextPainter(
                  text: TextSpan(text: tab, style: style),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout())
                    .width)
            .toList();
        final gap = (constraints.maxWidth - widths.reduce((a, b) => a + b)) /
            (tabs.length - 1);
        final positions = <double>[0];
        for (var index = 1; index < tabs.length; index++) {
          positions.add(positions.last + widths[index - 1] + gap);
        }

        return SizedBox(
          height: 32,
          child: Stack(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: tabs
                    .map(
                      (tab) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelected(tab),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Text(
                            tab,
                            style:
                                style.copyWith(color: AppPalette.text(context)),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                left: positions[selectedIndex],
                bottom: 0,
                width: widths[selectedIndex],
                height: 3,
                child: const ColoredBox(color: _MarketplacePageState._red),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MarketplaceSearchPage extends StatefulWidget {
  const _MarketplaceSearchPage({required this.products});
  final List<_Product> products;

  @override
  State<_MarketplaceSearchPage> createState() => _MarketplaceSearchPageState();
}

class _MarketplaceSearchPageState extends State<_MarketplaceSearchPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _controller.text.trim().toLowerCase();
    final products = widget.products
        .where(
            (item) => query.isEmpty || item.title.toLowerCase().contains(query))
        .toList();
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              LogoBackMorph(
                tag: 'marketplace-logo-back',
                showBack: true,
                onTap: () => Navigator.pop(context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: MorphingSearchBar(
                    controller: _controller,
                    hintText: 'Search music',
                    heroTag: 'marketplace-search',
                    width: MediaQuery.sizeOf(context).width - 100,
                    autoExpand: true,
                    onChanged: (_) => setState(() {}),
                    onClose: () => Navigator.pop(context),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 34),
            Text.rich(TextSpan(
              text: 'Search',
              style: TextStyle(
                fontFamily: _MarketplacePageState._font,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: AppPalette.text(context),
              ),
              children: const [
                TextSpan(
                    text: ' .',
                    style: TextStyle(color: _MarketplacePageState._red))
              ],
            )),
            const SizedBox(height: 23),
            Expanded(
              child: products.isEmpty
                  ? Center(
                      child: Text('No music found',
                          style: TextStyle(
                              fontFamily: _MarketplacePageState._font,
                              color: AppPalette.muted(context))),
                    )
                  : ListView.separated(
                      physics: const BouncingScrollPhysics(),
                      itemCount: products.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) => _MarketplaceSearchResult(
                        product: products[index],
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => _MarketplaceProductPage(
                                product: products[index]),
                          ),
                        ),
                      ),
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _MarketplaceSearchResult extends StatelessWidget {
  const _MarketplaceSearchResult({required this.product, required this.onTap});
  final _Product product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 108,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppPalette.page(context),
              border: Border.all(color: AppPalette.border(context)),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(children: [
              _MarketplaceArtworkPlaceholder(
                width: 90,
                height: 90,
                borderRadius: 7,
                imageUrl: product.coverUrl,
              ),
              const SizedBox(width: 13),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(product.title,
                        style: TextStyle(
                          fontFamily: _MarketplacePageState._font,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.text(context),
                        )),
                    const SizedBox(height: 7),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color:
                            _MarketplacePageState._red.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(product.category,
                          style: const TextStyle(
                            fontFamily: _MarketplacePageState._font,
                            color: _MarketplacePageState._red,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                          )),
                    ),
                    const Spacer(),
                    Text('by ${product.ownerName}',
                        style: TextStyle(
                          fontFamily: _MarketplacePageState._font,
                          fontSize: 10,
                          color: AppPalette.muted(context),
                        )),
                  ])),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                const Spacer(),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: _MarketplacePageState._red,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.arrow_forward_rounded,
                      size: 16, color: Colors.white),
                ),
              ]),
            ]),
          ),
        ),
      );
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({
    required this.product,
    required this.onTap,
  });
  final _Product product;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: AppPalette.page(context),
                border:
                    Border.all(color: AppPalette.border(context), width: 1.1),
                borderRadius: BorderRadius.circular(10)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) =>
                      _MarketplaceArtworkPlaceholder(
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    borderRadius: 7,
                    imageUrl: product.coverUrl,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(product.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: _MarketplacePageState._font,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.text(context))),
              const SizedBox(height: 1),
              Text(product.category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: _MarketplacePageState._font,
                      fontSize: 10,
                      color: Color(0xFF989898))),
              const SizedBox(height: 1),
              Text('by ${product.ownerName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: _MarketplacePageState._font,
                      fontSize: 9.5,
                      color: AppPalette.muted(context))),
              const SizedBox(height: 3),
              Align(
                alignment: Alignment.centerRight,
                child: Text(product.price,
                    style: const TextStyle(
                        fontFamily: _MarketplacePageState._font,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: _MarketplacePageState._red)),
              ),
            ]),
          ),
        ),
      );
}

class _MarketplaceProductPage extends StatefulWidget {
  const _MarketplaceProductPage({required this.product});

  final _Product product;

  @override
  State<_MarketplaceProductPage> createState() =>
      _MarketplaceProductPageState();
}

class _MarketplaceProductPageState extends State<_MarketplaceProductPage> {
  static const _red = Color(0xFFCA000A);
  var _isPlaying = false;
  var _progress = 0.0;
  Timer? _previewTimer;

  bool get _isOwner =>
      widget.product.ownerId != null &&
      widget.product.ownerId == FirebaseAuth.instance.currentUser?.uid;

  Future<void> _deleteListing() async {
    final listingId = widget.product.listingId;
    if (listingId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppPalette.surface(dialogContext),
        title: Text('Delete product',
            style: TextStyle(color: AppPalette.text(dialogContext))),
        content: Text('This will permanently remove your listing.',
            style: TextStyle(color: AppPalette.muted(dialogContext))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: _red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await SocialService.instance.deleteMarketplaceListing(listingId);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete product: $error')),
        );
      }
    }
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    super.dispose();
  }

  void _togglePreview() {
    setState(() => _isPlaying = !_isPlaying);
    _previewTimer?.cancel();
    if (!_isPlaying) {
      return;
    }
    _previewTimer = Timer.periodic(const Duration(milliseconds: 80), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _progress += 0.008;
        if (_progress >= 1) {
          _progress = 0;
          _isPlaying = false;
          timer.cancel();
        }
      });
    });
  }

  String get _description {
    if (widget.product.description.trim().isNotEmpty) {
      return widget.product.description.trim();
    }
    switch (widget.product.title) {
      case 'Glance':
        return 'An intimate, cinematic track with a clear melodic hook and a soft, forward pulse.';
      case 'Moonlight':
        return 'A warm late-night instrumental with gentle movement and an understated glow.';
      default:
        return 'A dark and addictive R&B track layered with smooth vocals, heavy bass, and moody melodies. Blending confidence with vulnerability, it captures the tension between desire, heartbreak, and self control.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = AppPalette.page(context);
    final text = AppPalette.text(context);
    final muted = AppPalette.muted(context);
    final product = widget.product;

    return Scaffold(
      backgroundColor: page,
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 112),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppBackButton(
                        color: text,
                        size: 21,
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                      _DetailIconButton(
                        icon: Icons.shopping_cart_outlined,
                        outlined: true,
                        onTap: () {},
                      ),
                      const SizedBox(width: 9),
                      _DetailIconButton(
                        icon: Icons.search_rounded,
                        onTap: () => Navigator.of(context).push(
                          morphSearchRoute(
                            (_) => const _MarketplaceSearchPage(
                                products: _marketplaceProducts),
                          ),
                        ),
                      ),
                      if (_isOwner) ...[
                        const SizedBox(width: 9),
                        _DetailIconButton(
                          icon: Icons.delete_outline_rounded,
                          outlined: true,
                          onTap: _deleteListing,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 46),
                  Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: _MarketplaceArtworkPlaceholder(
                        width: double.infinity,
                        height: double.infinity,
                        borderRadius: 7,
                        imageUrl: product.coverUrl,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          product.title,
                          style: TextStyle(
                            fontFamily: _MarketplacePageState._font,
                            fontSize: 25,
                            fontWeight: FontWeight.w700,
                            color: text,
                          ),
                        ),
                      ),
                      Material(
                        color: _red,
                        shape: const CircleBorder(),
                        child: InkWell(
                          onTap: _togglePreview,
                          customBorder: const CircleBorder(),
                          child: SizedBox(
                            height: 46,
                            width: 46,
                            child: Icon(
                              _isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 31,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text.rich(
                    TextSpan(
                      text: 'By: ',
                      style: TextStyle(
                        fontFamily: _MarketplacePageState._font,
                        fontSize: 11,
                        color: text,
                      ),
                      children: [
                        TextSpan(
                          text: product.ownerName,
                          style: const TextStyle(color: _red),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 19),
                  _TrackProgress(
                    progress: _progress,
                    onChanged: (value) => setState(() => _progress = value),
                  ),
                  const SizedBox(height: 7),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('0:00', style: _smallTimeStyle),
                      Text('2:30', style: _smallTimeStyle),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Wrap(
                    spacing: 13,
                    children: [
                      _GenreChip('R&B'),
                      _GenreChip('Modern'),
                    ],
                  ),
                  const SizedBox(height: 21),
                  Text('About This Track',
                      style: TextStyle(
                        fontFamily: _MarketplacePageState._font,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: text,
                      )),
                  const SizedBox(height: 12),
                  Text(_description,
                      style: TextStyle(
                        fontFamily: _MarketplacePageState._font,
                        fontSize: 11,
                        height: 1.26,
                        color: text,
                      )),
                  const SizedBox(height: 18),
                  Text('License',
                      style: TextStyle(
                        fontFamily: _MarketplacePageState._font,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: text,
                      )),
                  const SizedBox(height: 10),
                  Row(children: [
                    Text(
                      product.category == 'Music'
                          ? 'MP3, wav'
                          : product.category,
                      style: TextStyle(
                        fontFamily: _MarketplacePageState._font,
                        fontSize: 11,
                        color: muted,
                      ),
                    ),
                    const Spacer(),
                    Text(product.price,
                        style: const TextStyle(
                          fontFamily: _MarketplacePageState._font,
                          color: _red,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        )),
                  ]),
                ],
              ),
            ),
            Positioned(
              left: 22,
              right: 22,
              bottom: 22,
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.of(context).pop(product),
                    icon: const Icon(Icons.shopping_cart_rounded, size: 17),
                    label: const Text('Add to cart'),
                    style: ElevatedButton.styleFrom(
                      elevation: 0,
                      backgroundColor: _red,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(7)),
                      textStyle: const TextStyle(
                        fontFamily: _MarketplacePageState._font,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _smallTimeStyle = TextStyle(
  fontFamily: _MarketplacePageState._font,
  fontSize: 9,
  color: Color(0xFF555555),
);

class _DetailIconButton extends StatelessWidget {
  const _DetailIconButton({
    required this.icon,
    required this.onTap,
    this.outlined = false,
  });
  final IconData icon;
  final VoidCallback onTap;
  final bool outlined;

  @override
  Widget build(BuildContext context) => Material(
        color:
            outlined ? Colors.transparent : _MarketplaceProductPageState._red,
        shape: CircleBorder(
            side: outlined
                ? const BorderSide(color: _MarketplaceProductPageState._red)
                : BorderSide.none),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            height: 37,
            width: 37,
            child: Icon(icon,
                size: 19,
                color: outlined
                    ? _MarketplaceProductPageState._red
                    : Colors.white),
          ),
        ),
      );
}

class _TrackProgress extends StatelessWidget {
  const _TrackProgress({required this.progress, required this.onChanged});
  final double progress;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          activeTrackColor: _MarketplaceProductPageState._red,
          inactiveTrackColor: const Color(0xFFD8D6D4),
          thumbColor: _MarketplaceProductPageState._red,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
        ),
        child: Slider(value: progress, onChanged: onChanged),
      );
}

class _GenreChip extends StatelessWidget {
  const _GenreChip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: _MarketplaceProductPageState._red,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label,
            style: const TextStyle(
              fontFamily: _MarketplacePageState._font,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            )),
      );
}

class _CartPage extends StatefulWidget {
  const _CartPage({required this.items});
  final List<_CartItem> items;

  @override
  State<_CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<_CartPage> {
  static const _red = Color(0xFFCA000A);
  late List<_CartItem> _items;

  @override
  void initState() {
    super.initState();
    _items = widget.items.map((item) => item.copy()).toList();
  }

  double get _total => _items.fold(
      0, (sum, item) => sum + item.quantity * _priceOf(item.product.price));

  void _close() => Navigator.of(context).pop(_items);

  Future<void> _checkout() async {
    final invalid = _items.any((item) => item.product.listingId == null);
    if (invalid) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Refresh your cart before checkout. One product is no longer available.'),
      ));
      return;
    }
    final paid = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MarketplaceCheckoutSheet(
          items: _items.map((item) => item.copy()).toList()),
    );
    if (paid == true && mounted) {
      setState(() => _items.clear());
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const MarketplacePurchasesPage(
                showPurchaseConfirmation: true,
              )));
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = AppPalette.page(context);
    final text = AppPalette.text(context);
    final muted = AppPalette.muted(context);
    final border = AppPalette.border(context);
    final count = _items.fold(0, (sum, item) => sum + item.quantity);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _close();
        }
      },
      child: Scaffold(
        backgroundColor: page,
        body: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              24 + MediaQuery.paddingOf(context).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  AppBackButton(color: text, size: 21, onPressed: _close),
                  const Spacer(),
                  _DetailIconButton(
                    icon: Icons.shopping_cart_outlined,
                    outlined: true,
                    onTap: () {},
                  ),
                  const SizedBox(width: 8),
                  _DetailIconButton(icon: Icons.search_rounded, onTap: () {}),
                ]),
                const SizedBox(height: 22),
                Text.rich(TextSpan(
                  text: 'Your Cart',
                  style: TextStyle(
                    fontFamily: _MarketplacePageState._font,
                    color: text,
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                  ),
                  children: const [
                    TextSpan(text: ' .', style: TextStyle(color: _red)),
                  ],
                )),
                const SizedBox(height: 10),
                Row(children: [
                  Text('$count ${count == 1 ? 'item' : 'items'} in your cart',
                      style: TextStyle(
                        fontFamily: _MarketplacePageState._font,
                        color: text,
                        fontSize: 13,
                      )),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _items.isEmpty
                        ? null
                        : () => setState(() => _items.clear()),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: const Text('Clear all'),
                    style: TextButton.styleFrom(
                      foregroundColor: _red,
                      padding: EdgeInsets.zero,
                      textStyle: const TextStyle(
                        fontFamily: _MarketplacePageState._font,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 20),
                SizedBox(
                  height: _items.isEmpty
                      ? 120
                      : (_items.length * 177.0).clamp(166.0, 400.0),
                  child: _items.isEmpty
                      ? Center(
                          child: Text('Your cart is empty',
                              style: TextStyle(
                                fontFamily: _MarketplacePageState._font,
                                fontSize: 16,
                                color: muted,
                              )),
                        )
                      : ListView.separated(
                          physics: const BouncingScrollPhysics(),
                          itemCount: _items.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 11),
                          itemBuilder: (context, index) => _CartItemCard(
                            item: _items[index],
                            onDecrease: () => setState(() {
                              if (_items[index].quantity == 1) {
                                _items.removeAt(index);
                              } else {
                                _items[index].quantity--;
                              }
                            }),
                            onIncrease: () =>
                                setState(() => _items[index].quantity++),
                            onDelete: () =>
                                setState(() => _items.removeAt(index)),
                          ),
                        ),
                ),
                const SizedBox(height: 16),
                Text('Order summary',
                    style: TextStyle(
                      fontFamily: _MarketplacePageState._font,
                      color: text,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    )),
                const SizedBox(height: 20),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  decoration: BoxDecoration(
                    border: Border.all(color: border),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Column(children: [
                    _SummaryLine(
                        label: 'Subtotal', value: _money(_total), color: text),
                    const SizedBox(height: 16),
                    _SummaryLine(
                        label: 'Tax (0%)', value: r'$0.00', color: text),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      child: Divider(height: 1, color: border),
                    ),
                    _SummaryLine(
                        label: 'Total',
                        value: _money(_total),
                        color: _red,
                        bold: true),
                  ]),
                ),
                const SizedBox(height: 19),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _items.isEmpty ? null : _checkout,
                    icon: const Icon(Icons.shopping_cart_rounded, size: 19),
                    label: const Text('Proceed to checkout'),
                    style: ElevatedButton.styleFrom(
                      elevation: 0,
                      backgroundColor: _red,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFBDB9B7),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(7)),
                      textStyle: const TextStyle(
                        fontFamily: _MarketplacePageState._font,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.lock_rounded, color: muted, size: 16),
                    const SizedBox(width: 8),
                    Text('Secure checkout',
                        style: TextStyle(
                          fontFamily: _MarketplacePageState._font,
                          color: muted,
                          fontSize: 12,
                        )),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MarketplaceCheckoutSheet extends StatefulWidget {
  const _MarketplaceCheckoutSheet({required this.items});
  final List<_CartItem> items;

  @override
  State<_MarketplaceCheckoutSheet> createState() =>
      _MarketplaceCheckoutSheetState();
}

class _MarketplaceCheckoutSheetState extends State<_MarketplaceCheckoutSheet> {
  MarketplacePayment? _payment;
  String? _error;
  bool _creating = false;
  bool _checking = false;
  bool _savingQr = false;
  Duration _remaining = Duration.zero;
  Timer? _expiryTimer;
  Timer? _verificationTimer;
  int _verificationScheduleIndex = 0;
  DateTime? _verificationStartedAt;

  static const _verificationSchedule = <Duration>[
    Duration(seconds: 20),
    Duration(seconds: 40),
    Duration(seconds: 60),
    Duration(seconds: 80),
  ];

  double get _total => widget.items.fold(
      0, (sum, item) => sum + item.quantity * _priceOf(item.product.price));

  Future<void> _createCheckout() async {
    setState(() {
      _creating = true;
      _error = null;
    });
    _verificationTimer?.cancel();
    _verificationScheduleIndex = 0;
    _verificationStartedAt = null;
    try {
      final payment = await MarketplacePaymentService.createCheckout([
        for (final item in widget.items)
          MarketplaceCheckoutItem(
            listingId: item.product.listingId!,
            quantity: item.quantity,
          ),
      ]);
      final qr = payment.qrImage;
      if (payment.id.isEmpty ||
          qr == null ||
          qr.isEmpty ||
          !qr.startsWith('data:image/png;base64,')) {
        throw StateError(
            'The payment server did not return a valid KHQR. Please try again.');
      }
      if (mounted) {
        setState(() {
          _payment = payment;
          _remaining = payment.expiresAt.difference(DateTime.now());
          _verificationStartedAt = DateTime.now();
        });
        _startExpiryCountdown();
        _scheduleNextVerification();
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _startExpiryCountdown() {
    _expiryTimer?.cancel();
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final payment = _payment;
      if (!mounted || payment == null) return;
      final remaining = payment.expiresAt.difference(DateTime.now());
      setState(
          () => _remaining = remaining.isNegative ? Duration.zero : remaining);
      if (remaining.isNegative) {
        _expiryTimer?.cancel();
        _verificationTimer?.cancel();
      }
    });
  }

  void _scheduleNextVerification() {
    _verificationTimer?.cancel();
    final payment = _payment;
    final startedAt = _verificationStartedAt;
    if (!mounted ||
        payment == null ||
        startedAt == null ||
        !payment.expiresAt.isAfter(DateTime.now()) ||
        _verificationScheduleIndex >= _verificationSchedule.length) {
      return;
    }
    final target =
        startedAt.add(_verificationSchedule[_verificationScheduleIndex++]);
    final delay = target.difference(DateTime.now());
    final safeDelay = delay.isNegative ? Duration.zero : delay;
    if (payment.expiresAt.difference(DateTime.now()) <= safeDelay) {
      return;
    }
    _verificationTimer = Timer(safeDelay, () async {
      await _verify(automatic: true);
      if (mounted && _payment?.status == 'pending') {
        _scheduleNextVerification();
      }
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _verificationTimer?.cancel();
    super.dispose();
  }

  Future<void> _verify({bool automatic = false}) async {
    final payment = _payment;
    if (payment == null ||
        _checking ||
        !payment.expiresAt.isAfter(DateTime.now())) {
      return;
    }
    setState(() => _checking = true);
    try {
      final result = await MarketplacePaymentService.verify(payment.id);
      if (!mounted) return;
      if (result.status == 'paid') {
        _verificationTimer?.cancel();
        _expiryTimer?.cancel();
        Navigator.pop(context, true);
      } else if (result.status == 'expired') {
        _verificationTimer?.cancel();
        _expiryTimer?.cancel();
        setState(() {
          _payment = result;
          _remaining = Duration.zero;
          _error = 'This QR has expired. Close checkout and try again.';
        });
      } else {
        setState(() {
          _payment = result;
          if (!automatic) {
            _error =
                'Payment not confirmed yet. It will check again automatically.';
          }
        });
      }
    } catch (error) {
      if (mounted && !automatic) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _openAbaWithQr() async {
    final payment = _payment;
    final raw = payment?.qrImage;
    if (raw == null || raw.isEmpty) return;
    // Match plan billing: share the generated QR with ABA first. Android
    // cannot drive ABA's private Scan / Gallery controls directly.
    try {
      final bytes = base64Decode(raw.split(',').last);
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        try {
          const channel = MethodChannel('augment/aba_share');
          final opened =
              await channel.invokeMethod<bool>('shareToAba', {'bytes': bytes});
          if (opened == true) {
            if (mounted) setState(() => _error = null);
            return;
          }
        } catch (_) {
          // Use the platform share sheet when ABA's direct intent is absent.
        }
      }
      final temp = await getTemporaryDirectory();
      final file = File('${temp.path}/augment_marketplace_khqr.png');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        text: 'Scan with ABA Mobile',
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
      if (mounted) setState(() => _error = null);
      return;
    } catch (_) {
      // Fall through to the same Bakong-link fallback as plan billing.
    }
    final link = payment?.paymentLink;
    if (link != null && link.isNotEmpty) {
      try {
        if (await launchUrl(Uri.parse(link),
            mode: LaunchMode.externalApplication)) {
          if (mounted) setState(() => _error = null);
          return;
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() => _error =
          'Could not open ABA. Save the QR and select it from your ABA scan gallery.');
    }
  }

  Future<void> _saveQr() async {
    final raw = _payment?.qrImage;
    if (raw == null || raw.isEmpty || _savingQr) return;
    setState(() => _savingQr = true);
    try {
      await FileSaver.instance.saveFile(
        name: 'augment_marketplace_khqr',
        bytes: base64Decode(raw.split(',').last),
        fileExtension: 'png',
        mimeType: MimeType.png,
      );
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not download the QR. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _savingQr = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppPalette.text(context);
    final muted = AppPalette.muted(context);
    final qrData = _payment?.qrImage;
    Uint8List? qrBytes;
    if (qrData != null && qrData.contains(',')) {
      try {
        qrBytes = base64Decode(qrData.split(',').last);
      } catch (_) {}
    }
    final expired = _payment != null && _remaining == Duration.zero;
    final countdown = _payment == null
        ? null
        : '${_remaining.inMinutes.toString().padLeft(2, '0')}:${(_remaining.inSeconds % 60).toString().padLeft(2, '0')}';
    return Material(
      color: AppPalette.page(context),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              20, 10, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: AppPalette.border(context),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 18),
            Text('Secure checkout',
                style: TextStyle(
                    color: text, fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 5),
            Text(
                '${widget.items.length} product${widget.items.length == 1 ? '' : 's'} · ${_money(_total)}',
                style: TextStyle(color: muted)),
            const SizedBox(height: 20),
            if (_payment == null) ...[
              _CheckoutMethodCard(
                icon: Icons.qr_code_2_rounded,
                title: 'KHQR',
                subtitle:
                    'Scan with ABA or Bakong, or open ABA Mobile from the QR screen.',
                buttonLabel: _creating ? 'Generating…' : 'Generate KHQR',
                onTap: _creating ? null : _createCheckout,
              ),
              const SizedBox(height: 10),
              _CheckoutMethodCard(
                icon: Icons.credit_card_rounded,
                title: 'Credit card',
                subtitle:
                    'Check Visa or Mastercard details. Bank authorization is required to complete payment.',
                buttonLabel: 'Card details',
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  useSafeArea: true,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => const KeyboardAwareSheet(
                    child: _CardValidationSheet(),
                  ),
                ),
              ),
            ] else ...[
              Column(children: [
                Text('Scan to Pay',
                    style: TextStyle(
                        color: text,
                        fontSize: 23,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 5),
                Text('${_money(_payment!.amount)} ${_payment!.currency}',
                    style: const TextStyle(
                        color: Color(0xFFCA000A),
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 14),
                Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: Theme.of(context).brightness == Brightness.dark
                          ? const [Color(0xFF292525), Color(0xFF1B1919)]
                          : const [Colors.white, Color(0xFFFFF7F2)],
                    ),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                        color: const Color(0xFFCA000A).withValues(alpha: .14)),
                  ),
                  child: Column(children: [
                    Container(
                      height: 66,
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFFE22930),
                            Color(0xFFBA0007),
                            Color(0xFF540003),
                          ],
                        ),
                      ),
                      child: Row(children: [
                        const Expanded(
                          child: Text('augment.',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -1)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 11, vertical: 7),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .13),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text('KHQR',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1)),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 16),
                    Text('Scan with ABA Mobile or Bakong',
                        style: TextStyle(
                            color: text, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 12),
                    if (qrBytes != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20)),
                        child: Image.memory(qrBytes, width: 214, height: 214),
                      )
                    else
                      const SizedBox(
                          height: 214,
                          child: Center(child: Text('QR unavailable'))),
                    const SizedBox(height: 10),
                    Text(
                        '${_payment!.recipientName ?? 'Augment'} · ${_money(_payment!.amount)}',
                        style: TextStyle(
                            color: muted, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ]),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: expired ? null : _openAbaWithQr,
                icon: const Icon(Icons.account_balance_rounded),
                label: const Text('Pay with ABA Mobile'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: expired || _savingQr ? null : _saveQr,
                icon: _savingQr
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download_rounded),
                label: Text(_savingQr ? 'Saving QR…' : 'Download QR'),
              ),
              const SizedBox(height: 10),
              if (countdown != null)
                Text(
                    expired
                        ? 'QR expired — generate a new one.'
                        : 'QR expires in $countdown',
                    style: const TextStyle(
                        color: Color(0xFFBA0007), fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFCA000A),
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: _checking || expired ? null : () => _verify(),
                icon: _checking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.verified_rounded),
                label: const Text('I paid — check payment'),
              ),
              const SizedBox(height: 9),
              Text(
                  'Use ABA Mobile, Bakong, or another KHQR bank app. Payment checks run automatically at 20, 40, 60, and 80 seconds. Your order is released only after Bakong confirms payment.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted, fontSize: 12, height: 1.35)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 13),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Color(0xFFBA0007), fontSize: 12)),
            ],
          ]),
        ),
      ),
    );
  }
}

class _CardValidationSheet extends StatefulWidget {
  const _CardValidationSheet();

  @override
  State<_CardValidationSheet> createState() => _CardValidationSheetState();
}

class _CardValidationSheetState extends State<_CardValidationSheet> {
  final _number = TextEditingController();
  final _expiryMonth = TextEditingController();
  final _expiryYear = TextEditingController();
  final _cvc = TextEditingController();
  final _cvcFocus = FocusNode();
  String? _message;
  bool _showBack = false;

  @override
  void initState() {
    super.initState();
    _cvcFocus.addListener(
        () => mounted ? setState(() => _showBack = _cvcFocus.hasFocus) : null);
  }

  String get _digits => _number.text.replaceAll(RegExp(r'\D'), '');
  String get _expiry => '${_expiryMonth.text}/${_expiryYear.text}';

  String get _cardBrand {
    return cardNumberBrand(_number.text);
  }

  String get _displayNumber {
    final digits = _digits;
    if (digits.isEmpty) return '•••• •••• •••• ••••';
    final padded = '$digits••••••••••••••••'
        .substring(0, digits.length > 16 ? digits.length : 16);
    return padded
        .replaceAllMapped(RegExp(r'.{1,4}'), (match) => '${match.group(0)} ')
        .trimRight();
  }

  void _validate() {
    final expiry = RegExp(r'^(0[1-9]|1[0-2])/(\d{2})$').firstMatch(_expiry);
    final now = DateTime.now();
    final validExpiry = expiry != null &&
        ((2000 + int.parse(expiry.group(2)!)) > now.year ||
            ((2000 + int.parse(expiry.group(2)!)) == now.year &&
                int.parse(expiry.group(1)!) >= now.month));
    final validCvc = RegExp(r'^\d{3}$').hasMatch(_cvc.text.trim());
    setState(() {
      _message = isValidCardNumber(_number.text) && validExpiry && validCvc
          ? 'Card details are valid. Connect a payment provider to charge it.'
          : 'Check the card number, expiry date, and security code.';
    });
  }

  @override
  void dispose() {
    _number.dispose();
    _expiryMonth.dispose();
    _expiryYear.dispose();
    _cvc.dispose();
    _cvcFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
        color: AppPalette.page(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (MediaQuery.sizeOf(context).height -
                      MediaQuery.viewInsetsOf(context).bottom -
                      MediaQuery.paddingOf(context).top -
                      12)
                  .clamp(0.0, MediaQuery.sizeOf(context).height * .88),
            ),
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Center(
                  child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                          color: AppPalette.border(context),
                          borderRadius: BorderRadius.circular(8))),
                  const SizedBox(height: 18),
                  const Icon(Icons.credit_card_rounded,
                      color: Color(0xFFCA000A), size: 34),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: Text('Card payment',
                          style: TextStyle(
                              color: AppPalette.text(context),
                              fontSize: 21,
                              fontWeight: FontWeight.w800)),
                    ),
                    IconButton(
                      tooltip: 'Close card payment',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                      color: AppPalette.text(context),
                    ),
                  ]),
                  const SizedBox(height: 5),
                  Text(
                      'Card format is checked on this device. A payment provider is required to verify or charge a bank card.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppPalette.muted(context),
                          fontSize: 12,
                          height: 1.35)),
                  const SizedBox(height: 18),
                  _CheckoutPaymentCard(
                    showBack: _showBack,
                    onTap: () => setState(() => _showBack = !_showBack),
                    brand: _cardBrand,
                    number: _displayNumber,
                    expiry:
                        _expiryMonth.text.isEmpty && _expiryYear.text.isEmpty
                            ? 'MM / YY'
                            : _expiry,
                    cvc: _cvc.text,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                      controller: _number,
                      keyboardType: TextInputType.number,
                      maxLength: 19,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Visa / Mastercard number',
                        prefixIcon: _CardBrandMark(brand: _cardBrand),
                      )),
                  ResponsivePaymentFields(
                    expiry: _expiryFields(context),
                    securityCode: _cvcField(),
                  ),
                  if (_message != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(_message!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: _message!.startsWith('Card')
                                    ? const Color(0xFF267342)
                                    : const Color(0xFFBA0007),
                                fontSize: 12))),
                  const SizedBox(height: 14),
                  FilledButton(
                      onPressed: _validate,
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFCA000A),
                          minimumSize: const Size.fromHeight(50)),
                      child: const Text('Check card details')),
                ]),
              )),
            ),
          ),
        ),
      );

  Widget _expiryFields(BuildContext context) => Row(children: [
        Expanded(
            child: TextField(
          controller: _expiryMonth,
          keyboardType: TextInputType.number,
          maxLength: 2,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'MM', counterText: ''),
        )),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('/',
              style: TextStyle(color: AppPalette.muted(context), fontSize: 20)),
        ),
        Expanded(
            child: TextField(
          controller: _expiryYear,
          keyboardType: TextInputType.number,
          maxLength: 2,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'YY', counterText: ''),
        )),
      ]);

  Widget _cvcField() => TextField(
        controller: _cvc,
        focusNode: _cvcFocus,
        keyboardType: TextInputType.number,
        obscureText: true,
        maxLength: 3,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(labelText: 'CVC', counterText: ''),
      );
}

class _CardLabel extends StatelessWidget {
  const _CardLabel({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(
                color: Color(0xCCFFFFFF),
                fontSize: 8,
                fontWeight: FontWeight.w700,
                letterSpacing: .7)),
        const SizedBox(height: 3),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700)),
      ]);
}

class _CardBrandMark extends StatelessWidget {
  const _CardBrandMark({required this.brand});
  final String brand;

  @override
  Widget build(BuildContext context) {
    if (brand == 'VISA') {
      return const Center(
          child: Text('VISA',
              style: TextStyle(
                  color: Color(0xFF1434CB),
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  fontStyle: FontStyle.italic)));
    }
    if (brand == 'mastercard') {
      return const Center(
        child: SizedBox(
          width: 29,
          height: 16,
          child: Stack(children: [
            Positioned(
                left: 2,
                child: CircleAvatar(
                    radius: 8, backgroundColor: Color(0xFFEB001B))),
            Positioned(
                right: 2,
                child: CircleAvatar(
                    radius: 8, backgroundColor: Color(0xFFF79E1B))),
          ]),
        ),
      );
    }
    return const Icon(Icons.credit_card_outlined);
  }
}

class _CheckoutPaymentCard extends StatelessWidget {
  const _CheckoutPaymentCard({
    required this.showBack,
    required this.onTap,
    required this.brand,
    required this.number,
    required this.expiry,
    required this.cvc,
  });
  final bool showBack;
  final VoidCallback onTap;
  final String brand;
  final String number;
  final String expiry;
  final String cvc;

  LinearGradient get _gradient => brand == 'VISA'
      ? const LinearGradient(
          colors: [Color(0xFF06184D), Color(0xFF0A3C92), Color(0xFF1459C7)])
      : brand == 'mastercard'
          ? const LinearGradient(
              colors: [Color(0xFF151515), Color(0xFF3D2020), Color(0xFF8D1F24)])
          : const LinearGradient(colors: [
              Color(0xFF101319),
              Color(0xFF333940),
              Color(0xFF16181B)
            ]);

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeInOutCubic,
        tween: Tween(end: showBack ? 1.0 : 0.0),
        builder: (context, turn, _) => GestureDetector(
          onTap: onTap,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, .0015)
              ..rotateY(turn * 3.141592653589793),
            child: AspectRatio(
                aspectRatio: 1.72,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: _gradient,
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 18,
                          offset: Offset(0, 9))
                    ],
                  ),
                  child: turn < .5
                      ? _front()
                      : Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.rotationY(3.141592653589793),
                          child: _back()),
                )),
          ),
        ),
      );

  Widget _front() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.contactless_rounded, color: Colors.white, size: 26),
          const Spacer(),
          Text(brand,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                  fontStyle: FontStyle.italic)),
        ]),
        const Spacer(),
        FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(number,
                maxLines: 1,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    letterSpacing: 1.3,
                    fontWeight: FontWeight.w600))),
        const SizedBox(height: 14),
        Align(
            alignment: Alignment.centerRight,
            child: _CardLabel(label: 'EXPIRES', value: expiry)),
      ]);

  Widget _back() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 2),
        Container(height: 24, color: Colors.black),
        const SizedBox(height: 6),
        const Text('AUTHORIZED SIGNATURE',
            style: TextStyle(
                color: Color(0xCCFFFFFF), fontSize: 8, letterSpacing: .8)),
        const SizedBox(height: 2),
        Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.centerRight,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(cvc.isEmpty ? 'CVV' : cvc,
              style: const TextStyle(
                  color: Color(0xFF222222),
                  letterSpacing: 2,
                  fontWeight: FontWeight.w800)),
        ),
        const Spacer(),
        Align(
            alignment: Alignment.centerRight,
            child: Text(brand,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic))),
      ]);
}

class _CheckoutMethodCard extends StatelessWidget {
  const _CheckoutMethodCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final String buttonLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: AppPalette.border(context)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFFFFE4E1),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: const Color(0xFFCA000A)),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: TextStyle(
                        color: AppPalette.text(context),
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: TextStyle(
                        color: AppPalette.muted(context),
                        fontSize: 12,
                        height: 1.3)),
                const SizedBox(height: 11),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFCA000A)),
                    onPressed: onTap,
                    child: Text(buttonLabel),
                  ),
                ),
              ])),
        ]),
      );
}

class _CartItemCard extends StatelessWidget {
  const _CartItemCard({
    required this.item,
    required this.onDecrease,
    required this.onIncrease,
    required this.onDelete,
  });
  final _CartItem item;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final text = AppPalette.text(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppPalette.border(context)),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _MarketplaceArtworkPlaceholder(
            width: 76,
            height: 76,
            borderRadius: 5,
            imageUrl: item.product.coverUrl,
          ),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.product.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: _MarketplacePageState._font,
                    color: text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  )),
              const SizedBox(height: 5),
              Text(item.product.category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _MarketplacePageState._font,
                    color: Color(0xFF959595),
                    fontSize: 12,
                  )),
            ]),
          ),
        ]),
        const SizedBox(height: 9),
        Row(children: [
          Expanded(
            child: Text(_money(_priceOf(item.product.price) * item.quantity),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: _MarketplacePageState._font,
                  color: _CartPageState._red,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                )),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            _QuantityButton(icon: Icons.remove_rounded, onTap: onDecrease),
            SizedBox(
                width: 28,
                child: Text('${item.quantity}',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: _MarketplacePageState._font,
                        color: text,
                        fontSize: 13))),
            _QuantityButton(icon: Icons.add_rounded, onTap: onIncrease),
            const SizedBox(width: 7),
            IconButton(
              tooltip: 'Remove product',
              onPressed: onDelete,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.delete_outline_rounded,
                  color: _CartPageState._red, size: 19),
            ),
          ]),
        ]),
      ]),
    );
  }
}

class _QuantityButton extends StatelessWidget {
  const _QuantityButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 16, color: AppPalette.text(context)),
        ),
      );
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine({
    required this.label,
    required this.value,
    required this.color,
    this.bold = false,
  });
  final String label;
  final String value;
  final Color color;
  final bool bold;
  @override
  Widget build(BuildContext context) => Row(children: [
        Text(label,
            style: TextStyle(
              fontFamily: _MarketplacePageState._font,
              fontSize: 12,
              color: color,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            )),
        const Spacer(),
        Text(value,
            style: TextStyle(
              fontFamily: _MarketplacePageState._font,
              fontSize: 12,
              color: color,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            )),
      ]);
}

double _priceOf(String price) =>
    double.tryParse(price.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;

String _money(double value) => '\$${value.toStringAsFixed(2)}';

class _NoResults extends StatelessWidget {
  const _NoResults();
  @override
  Widget build(BuildContext context) => const Padding(
      padding: EdgeInsets.only(top: 40),
      child: Center(
          child: Text('No music found',
              style: TextStyle(
                  fontFamily: _MarketplacePageState._font,
                  color: Color(0xFF8E8E8E)))));
}

class _Product {
  const _Product(this.title, this.category, this.price, this.asset,
      {this.ownerName = 'Augment user',
      this.description = '',
      this.coverUrl,
      this.listingId,
      this.ownerId});

  factory _Product.fromListing(MarketplaceListing listing) => _Product(
        listing.title,
        listing.category,
        '\$${listing.price.toStringAsFixed(2)}',
        listing.assetUrl ?? '',
        ownerName: listing.ownerName,
        description: listing.description,
        coverUrl: listing.coverUrl,
        listingId: listing.id,
        ownerId: listing.ownerId,
      );

  final String title;
  final String category;
  final String price;
  final String asset;
  final String ownerName;
  final String description;
  final String? coverUrl;
  final String? listingId;
  final String? ownerId;
}

class _MarketplaceArtworkPlaceholder extends StatelessWidget {
  const _MarketplaceArtworkPlaceholder({
    required this.width,
    required this.height,
    required this.borderRadius,
    this.imageUrl,
  });
  final double width;
  final double height;
  final double borderRadius;
  final String? imageUrl;

  bool get _hasImage =>
      imageUrl != null &&
      RegExp(r'\.(png|jpe?g|webp|gif)(\?.*)?$', caseSensitive: false)
          .hasMatch(imageUrl!);

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: AppPalette.isDark(context)
              ? const Color(0xFF2C2C2C)
              : const Color(0xFFE8E5E2),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        clipBehavior: Clip.antiAlias,
        alignment: Alignment.center,
        child: _hasImage
            ? (imageUrl!.startsWith('http')
                ? Image.network(imageUrl!,
                    fit: BoxFit.cover,
                    width: width,
                    height: height,
                    errorBuilder: (_, __, ___) => Icon(Icons.music_note_rounded,
                        color: AppPalette.muted(context),
                        size: height > 100 ? 42 : 26))
                : Image.asset(imageUrl!,
                    fit: BoxFit.cover, width: width, height: height))
            : Icon(Icons.music_note_rounded,
                color: AppPalette.muted(context), size: height > 100 ? 42 : 26),
      );
}

class _CartItem {
  _CartItem(this.product, {this.quantity = 1});
  final _Product product;
  int quantity;
  _CartItem copy() => _CartItem(product, quantity: quantity);
}
