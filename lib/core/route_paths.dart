/// Medora - Route path constants shared across layers.
library;

/// Path constants a service can use to build a route without importing
/// `presentation/router/app_router.dart` — a service must not depend on UI
/// code, but a background handler (e.g. a tapped notification) still needs
/// to know where a route lives. `AppRoutes` re-declares these same values
/// for the router itself, so the two cannot drift apart.
class RoutePaths {
  RoutePaths._();

  static const home = '/';
  static const doses = '/doses';
  static const rxDetail = '/rx/:id';
}
