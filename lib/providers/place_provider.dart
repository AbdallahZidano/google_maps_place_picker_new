import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_google_maps_webservices/geocoding.dart';
import 'package:flutter_google_maps_webservices/places.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_place_picker_mb_new/src/models/pick_result.dart';
import 'package:google_maps_place_picker_mb_new/src/place_picker.dart';
import 'package:http/http.dart';
import 'package:provider/provider.dart';

class PlaceProvider extends ChangeNotifier {
  PlaceProvider(
    String apiKey,
    String? proxyBaseUrl,
    Client? httpClient,
    Map<String, dynamic> apiHeaders,
  ) {
    places = GoogleMapsPlaces(
      apiKey: apiKey,
      baseUrl: proxyBaseUrl,
      httpClient: httpClient,
      apiHeaders: apiHeaders as Map<String, String>?,
    );
    geocoding = GoogleMapsGeocoding(
      apiKey: apiKey,
      baseUrl: proxyBaseUrl,
      httpClient: httpClient,
      apiHeaders: apiHeaders as Map<String, String>?,
    );
  }

  static PlaceProvider of(BuildContext context, {bool listen = true}) =>
      Provider.of<PlaceProvider>(context, listen: listen);

  late GoogleMapsPlaces places;
  late GoogleMapsGeocoding geocoding;
  String? sessionToken;
  bool isOnUpdateLocationCooldown = false;
  LocationAccuracy? desiredAccuracy;
  bool isAutoCompleteSearching = false;

  Future<void> updateCurrentLocation({bool gracefully = false}) async {
    bool serviceEnabled;
    LocationPermission permission;

    // Test if location services are enabled.
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Location services are not enabled don't continue
      // accessing the position and request users of the
      // App to enable the location services.
      if (gracefully) {
        // Or you can swallow the issue and respect the user's privacy
        return;
      }
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        // Permissions are denied, next time you could try
        // requesting permissions again (this is also where
        // Android's shouldShowRequestPermissionRationale
        // returned true. According to Android guidelines
        // your App should show an explanatory UI now.
        if (gracefully) {
          // Or you can swallow the issue and respect the user's privacy
          return;
        }
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      // Permissions are denied forever, handle appropriately.
      if (gracefully) {
        // Or you can swallow the issue and respect the user's privacy
        return;
      }
      return Future.error(
          'Location permissions are permanently denied, we cannot request permissions.');
    }

    _currentPosition = await Geolocator.getCurrentPosition(
      desiredAccuracy: desiredAccuracy ?? LocationAccuracy.best,
    );
  }

  Position? _currentPosition;
  Position? get currentPosition => _currentPosition;
  set currentPosition(Position? newPosition) {
    _currentPosition = newPosition;
    notifyListeners();
  }

  Timer? _debounceTimer;
  Timer? get debounceTimer => _debounceTimer;
  set debounceTimer(Timer? timer) {
    _debounceTimer = timer;
    notifyListeners();
  }

  CameraPosition? _previousCameraPosition;
  CameraPosition? get prevCameraPosition => _previousCameraPosition;
  setPrevCameraPosition(CameraPosition? prePosition) {
    _previousCameraPosition = prePosition;
  }

  CameraPosition? _currentCameraPosition;
  CameraPosition? get cameraPosition => _currentCameraPosition;
  setCameraPosition(CameraPosition? newPosition) {
    _currentCameraPosition = newPosition;
  }

  PickResult? _selectedPlace;
  PickResult? get selectedPlace => _selectedPlace;
  set selectedPlace(PickResult? result) {
    _selectedPlace = result;
    notifyListeners();
  }

  SearchingState _placeSearchingState = SearchingState.Idle;
  SearchingState get placeSearchingState => _placeSearchingState;
  set placeSearchingState(SearchingState newState) {
    _placeSearchingState = newState;
    notifyListeners();
  }

  GoogleMapController? _mapController;
  GoogleMapController? get mapController => _mapController;
  set mapController(GoogleMapController? controller) {
    _mapController = controller;
    notifyListeners();
  }

  PinState _pinState = PinState.Preparing;
  PinState get pinState => _pinState;
  set pinState(PinState newState) {
    _pinState = newState;
    notifyListeners();
  }

  bool _isSeachBarFocused = false;
  bool get isSearchBarFocused => _isSeachBarFocused;
  set isSearchBarFocused(bool focused) {
    _isSeachBarFocused = focused;
    notifyListeners();
  }

  MapType _mapType = MapType.normal;
  MapType get mapType => _mapType;
  setMapType(MapType mapType, {bool notify = false}) {
    _mapType = mapType;
    if (notify) notifyListeners();
  }

  switchMapType() {
    _mapType = MapType.values[(_mapType.index + 1) % MapType.values.length];
    if (_mapType == MapType.none) _mapType = MapType.normal;
    notifyListeners();
  }

  // Caches for API responses
  final Map<String, GeocodingResponse> _geocodingCache = {};
  final Map<String, Future<GeocodingResponse>> _geocodingInFlight = {};
  final Map<String, PlacesAutocompleteResponse> _autocompleteCache = {};
  final Map<String, Future<PlacesAutocompleteResponse>> _autocompleteInFlight =
      {};
  final Map<String, PlacesDetailsResponse> _placeDetailsCache = {};
  final Map<String, Future<PlacesDetailsResponse>> _placeDetailsInFlight = {};

  // Optimized geocoding by location with timing logs
  Future<GeocodingResponse> getGeocodingByLocation(Location location,
      {String? language}) async {
    final key = "${location.lat},${location.lng},${language ?? ''}";
    if (_geocodingCache.containsKey(key)) {
      print('[Geocoding][CACHE] $key');
      return _geocodingCache[key]!;
    }
    if (_geocodingInFlight.containsKey(key)) {
      print('[Geocoding][INFLIGHT] $key');
      return await _geocodingInFlight[key]!;
    }
    final start = DateTime.now();
    print('[Geocoding][REQUEST] $key - start');
    final future = geocoding.searchByLocation(location, language: language);
    _geocodingInFlight[key] = future;
    final response = await future;
    final duration = DateTime.now().difference(start);
    print(
        '[Geocoding][RESPONSE] $key - duration: ${duration.inMilliseconds} ms');
    if (response.status == "OK") {
      _geocodingCache[key] = response;
    }
    _geocodingInFlight.remove(key);
    return response;
  }

  // Optimized autocomplete with timing logs
  Future<PlacesAutocompleteResponse> getAutocomplete(
    String searchTerm, {
    String? sessionToken,
    Location? location,
    num? offset,
    num? radius,
    String? language,
    List<String>? types,
    List<Component>? components,
    bool? strictbounds,
    String? region,
  }) async {
    final key = [
      searchTerm,
      sessionToken,
      location?.lat,
      location?.lng,
      offset,
      radius,
      language,
      types?.join(','),
      components?.map((c) => c.toString()).join(','),
      strictbounds,
      region
    ].join('|');
    if (_autocompleteCache.containsKey(key)) {
      print('[Autocomplete][CACHE] $key');
      return _autocompleteCache[key]!;
    }
    if (_autocompleteInFlight.containsKey(key)) {
      print('[Autocomplete][INFLIGHT] $key');
      return await _autocompleteInFlight[key]!;
    }
    final start = DateTime.now();
    print('[Autocomplete][REQUEST] $key - start');
    final future = places.autocomplete(
      searchTerm,
      sessionToken: sessionToken,
      location: location,
      offset: offset,
      radius: radius,
      language: language,
      types: types ?? const [],
      components: components ?? const [],
      strictbounds: strictbounds ?? false,
      region: region,
    );
    _autocompleteInFlight[key] = future;
    final response = await future;
    final duration = DateTime.now().difference(start);
    print(
        '[Autocomplete][RESPONSE] $key - duration: ${duration.inMilliseconds} ms');
    if (response.status == "OK") {
      _autocompleteCache[key] = response;
    }
    _autocompleteInFlight.remove(key);
    return response;
  }

  // Optimized place details with timing logs
  Future<PlacesDetailsResponse> getPlaceDetailsById(String placeId,
      {String? sessionToken, String? language}) async {
    final key = [placeId, sessionToken, language].join('|');
    if (_placeDetailsCache.containsKey(key)) {
      print('[PlaceDetails][CACHE] $key');
      return _placeDetailsCache[key]!;
    }
    if (_placeDetailsInFlight.containsKey(key)) {
      print('[PlaceDetails][INFLIGHT] $key');
      return await _placeDetailsInFlight[key]!;
    }
    final start = DateTime.now();
    print('[PlaceDetails][REQUEST] $key - start');
    final future = places.getDetailsByPlaceId(
      placeId,
      sessionToken: sessionToken,
      language: language,
    );
    _placeDetailsInFlight[key] = future;
    final response = await future;
    final duration = DateTime.now().difference(start);
    print(
        '[PlaceDetails][RESPONSE] $key - duration: ${duration.inMilliseconds} ms');
    if (response.status == "OK") {
      _placeDetailsCache[key] = response;
    }
    _placeDetailsInFlight.remove(key);
    return response;
  }
}
