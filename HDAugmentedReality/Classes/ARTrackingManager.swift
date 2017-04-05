//
//  ARTrackingManager.swift
//  HDAugmentedRealityDemo
//
//  Created by Danijel Huis on 22/04/15.
//  Copyright (c) 2015 Danijel Huis. All rights reserved.
//

import UIKit
import CoreMotion
import CoreLocation


protocol ARTrackingManagerDelegate : class {
    func arTrackingManager(_ trackingManager: ARTrackingManager, didUpdateUserLocation location: CLLocation?)
    func arTrackingManager(_ trackingManager: ARTrackingManager, didUpdateReloadLocation location: CLLocation?)
    func arTrackingManager(_ trackingManager: ARTrackingManager, didFailToFindLocationAfter elapsedSeconds: TimeInterval)
    func logText(_ text: String)
}

extension ARTrackingManagerDelegate {
    func arTrackingManager(_ trackingManager: ARTrackingManager, didUpdateUserLocation location: CLLocation?) {}
    func arTrackingManager(_ trackingManager: ARTrackingManager, didUpdateReloadLocation location: CLLocation?) {}
    func arTrackingManager(_ trackingManager: ARTrackingManager, didFailToFindLocationAfter elapsedSeconds: TimeInterval) {}
    func logText(_ text: String) {}
}


/// Class used internally by ARViewController for location and orientation calculations.
open class ARTrackingManager: NSObject, CLLocationManagerDelegate {
    /**
     *      Defines whether altitude is taken into account when calculating distances. Set this to false if your annotations
     *      don't have altitude values. Note that this is only used for distance calculation, it doesn't have effect on vertical
     *      levels of annotations. Default value is false.
     */
    open var altitudeSensitive = false
    
    /**
     *      Specifies how often the visibilities of annotations are reevaluated.
     *
     *      Annotation's visibility depends on number of factors - azimuth, distance from user, vertical level etc.
     *      Note: These calculations are quite heavy if many annotations are present, so don't use value lower than 50m.
     *      Default value is 75m.
     *
     */
    open var reloadDistanceFilter: CLLocationDistance!    // Will be set in init
    
    /**
     *      Specifies how often are distances and azimuths recalculated for visible annotations.
     *      Default value is 25m.
     */
    open var userDistanceFilter: CLLocationDistance! {
        didSet {
            locationManager.distanceFilter = userDistanceFilter
        }
    }
    
    // MARK: Internal variables
    fileprivate(set) internal var locationManager: CLLocationManager = CLLocationManager()
    fileprivate(set) internal var tracking = false
    fileprivate(set) internal var userLocation: CLLocation?
    fileprivate(set) internal var heading: Double = 0
    internal weak var delegate: ARTrackingManagerDelegate?
    internal var orientation: CLDeviceOrientation = CLDeviceOrientation.portrait {
        didSet {
            locationManager.headingOrientation = orientation
        }
    }
    internal var pitch: Double {
        get {
            return calculatePitch()
        }
    }
    
    // MARK: Private
    fileprivate var motionManager: CMMotionManager = CMMotionManager()
    fileprivate var lastAcceleration: CMAcceleration = CMAcceleration(x: 0, y: 0, z: 0)
    fileprivate var reloadLocationPrevious: CLLocation?
    fileprivate var pitchPrevious: Double = 0
    fileprivate var reportLocationTimer: Timer?
    fileprivate var reportLocationDate: TimeInterval?
    fileprivate var debugLocation: CLLocation?
    fileprivate var locationSearchTimer: Timer? = nil
    fileprivate var locationSearchStartTime: TimeInterval? = nil
    
    
    override init() {
        super.init()
        initialize()
    }
    
    deinit {
        stopTracking()
    }
    
    fileprivate func initialize() {
        // Defaults
        reloadDistanceFilter = 75
        userDistanceFilter = 25
        
        // Setup location manager
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = CLLocationDistance(userDistanceFilter)
        locationManager.headingFilter = 1
        locationManager.delegate = self
    }
    
    // MARK: Tracking
    
    /**
     Starts location and motion manager
     
     - Parameter: notifyFailure if true, will call arTrackingManager:didFailToFindLocationAfter:
     */
    internal func startTracking(notifyLocationFailure: Bool = false) {
        // Request authorization if state is not determined
        if CLLocationManager.locationServicesEnabled() {
            if CLLocationManager.authorizationStatus() == CLAuthorizationStatus.notDetermined {
                if #available(iOS 8.0, *) {
                    self.locationManager.requestWhenInUseAuthorization()
                } else {
                    // Fallback on earlier versions
                }
                
            }
        }
        
        // Start motion and location managers
        motionManager.startAccelerometerUpdates()
        locationManager.startUpdatingHeading()
        locationManager.startUpdatingLocation()
        
        tracking = true
        
        // Location search
        stopLocationSearchTimer()
        if notifyLocationFailure {
            startLocationSearchTimer()
            
            // Calling delegate with value 0 to be flexible, for example user might want to show indicator when search is starting.
            delegate?.arTrackingManager(self, didFailToFindLocationAfter: 0)
        }
    }
    
    /// Stops location and motion manager
    internal func stopTracking() {
        reloadLocationPrevious = nil
        userLocation = nil
        reportLocationDate = nil
        
        // Stop motion and location managers
        motionManager.stopAccelerometerUpdates()
        locationManager.stopUpdatingHeading()
        locationManager.stopUpdatingLocation()
        
        tracking = false
        stopLocationSearchTimer()
    }
    
    // MARK: CLLocationManagerDelegate
    
    open func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = fmod(newHeading.trueHeading, 360.0)
    }
    
    open func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if locations.count > 0 {
            let location = locations[0]
            
            // Disregarding old and low quality location detections
            let age = location.timestamp.timeIntervalSinceNow;
            if age < -30 || location.horizontalAccuracy > 500 || location.horizontalAccuracy < 0 {
                print("Disregarding location: age: \(age), ha: \(location.horizontalAccuracy)")
                return
            }
            
            stopLocationSearchTimer()
            
            //println("== \(location!.horizontalAccuracy), \(age) \(location!.coordinate.latitude), \(location!.coordinate.longitude)" )
            userLocation = location
            
            // Setting altitude to 0 if altitudeSensitive == false
            if userLocation != nil && !altitudeSensitive {
                let location = userLocation!
                userLocation = CLLocation(
                    coordinate: location.coordinate,
                    altitude: 0,
                    horizontalAccuracy: location.horizontalAccuracy,
                    verticalAccuracy: location.verticalAccuracy,
                    timestamp: location.timestamp
                )
            }
            
            if debugLocation != nil { userLocation = debugLocation }
            
            if reloadLocationPrevious == nil {
                reloadLocationPrevious = userLocation
            }
            
            // Reporting location 5s after we get location, this will filter multiple locations calls and make only one delegate call
            let reportIsScheduled = reportLocationTimer != nil
            
            if reportLocationDate == nil {
                // First time, reporting immediately
                reportLocationToDelegate()
            } else if reportIsScheduled {
                // Report is already scheduled, doing nothing, it will report last location delivered in that 5s
            } else {
                // Scheduling report in 5s
                reportLocationTimer = Timer.scheduledTimer(
                    timeInterval: 5, target: self,
                    selector: #selector(ARTrackingManager.reportLocationToDelegate),
                    userInfo: nil, repeats: false
                )
            }
        }
    }
    
    internal func reportLocationToDelegate() {
        reportLocationTimer?.invalidate()
        reportLocationTimer = nil
        reportLocationDate = Date().timeIntervalSince1970
        
        guard
            let userLocation = userLocation,
            let reloadLocationPrevious = reloadLocationPrevious,
            let reloadDistanceFilter = reloadDistanceFilter
            else { return }
        
        delegate?.arTrackingManager(self, didUpdateUserLocation: userLocation)
        
        if reloadLocationPrevious.distance(from: userLocation) > reloadDistanceFilter {
            self.reloadLocationPrevious = userLocation
            delegate?.arTrackingManager(self, didUpdateReloadLocation: userLocation)
        }
    }
    
    // MARK: Calculations
    
    internal func calculatePitch() -> Double {
        if motionManager.accelerometerData == nil {
            return 0
        }
        
        let acceleration: CMAcceleration = motionManager.accelerometerData!.acceleration
        
        // Filtering data so its not jumping around
        let filterFactor: Double = 0.05
        lastAcceleration.x = (acceleration.x * filterFactor) + (lastAcceleration.x  * (1.0 - filterFactor))
        lastAcceleration.y = (acceleration.y * filterFactor) + (lastAcceleration.y  * (1.0 - filterFactor))
        lastAcceleration.z = (acceleration.z * filterFactor) + (lastAcceleration.z  * (1.0 - filterFactor))
        
        let deviceOrientation = orientation
        var angle: Double = 0
        
        if deviceOrientation == CLDeviceOrientation.portrait {
            angle = atan2(lastAcceleration.y, lastAcceleration.z)
            
        } else if deviceOrientation == CLDeviceOrientation.portraitUpsideDown {
            angle = atan2(-lastAcceleration.y, lastAcceleration.z)
            
        } else if deviceOrientation == CLDeviceOrientation.landscapeLeft {
            angle = atan2(lastAcceleration.x, lastAcceleration.z)
            
        } else if deviceOrientation == CLDeviceOrientation.landscapeRight {
            angle = atan2(-lastAcceleration.x, lastAcceleration.z)
            
        }
        
        angle += .pi / 2
        angle = (pitchPrevious + angle) / 2.0
        pitchPrevious = angle
        return angle
    }
    
    internal func azimuthFromUserToLocation(_ location: CLLocation) -> Double {
        var azimuth: Double = 0
        if userLocation == nil {
            return 0
        }
        
        let coordinate: CLLocationCoordinate2D = location.coordinate
        let userCoordinate: CLLocationCoordinate2D = userLocation!.coordinate
        
        // Calculating azimuth
        let latitudeDistance: Double = userCoordinate.latitude - coordinate.latitude
        let longitudeDistance: Double = userCoordinate.longitude - coordinate.longitude
        
        // Simplified azimuth calculation
        azimuth = radiansToDegrees(atan2(longitudeDistance, (latitudeDistance * Double(LAT_LON_FACTOR))))
        azimuth += 180.0
        
        return azimuth
    }
    
    internal func startDebugMode(_ location: CLLocation) {
        debugLocation = location
        userLocation = location
    }
    
    internal func stopDebugMode(_ location: CLLocation) {
        debugLocation = nil
        userLocation = nil
    }
    
    // MARK: Location search
    
    func startLocationSearchTimer(resetStartTime: Bool = true) {
        stopLocationSearchTimer()
        
        if resetStartTime {
            locationSearchStartTime = Date().timeIntervalSince1970
        }
        locationSearchTimer = Timer.scheduledTimer(
            timeInterval: 5, target: self,
            selector: #selector(ARTrackingManager.locationSearchTimerTick),
            userInfo: nil, repeats: false
        )
        
    }
    
    func stopLocationSearchTimer(resetStartTime: Bool = true) {
        locationSearchTimer?.invalidate()
        locationSearchTimer = nil
    }
    
    func locationSearchTimerTick() {
        guard let locationSearchStartTime = locationSearchStartTime else { return }
        let elapsedSeconds = Date().timeIntervalSince1970 - locationSearchStartTime
        
        startLocationSearchTimer(resetStartTime: false)
        delegate?.arTrackingManager(self, didFailToFindLocationAfter: elapsedSeconds)
    }
}
