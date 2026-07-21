import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.FitContributor;
import Toybox.Sensor;
import Toybox.Position;
import Toybox.Math;
import Toybox.Timer;
import Toybox.System;

class RiverSurfView extends WatchUi.View {

    // FIT Contributor Fields
    private var mWaveCountField = null;
    private var mTimeSurfingField = null;
    private var mMaxWaveSpeedField = null;
    private var mLongestWaveField = null;
    private var mWaveDurationField = null;

    // Recording Session
    private var mSession = null;

    // Surfing states
    enum SurfState {
        STATE_WAITING = 0,
        STATE_SURFING = 1,
        STATE_SWEPT = 2
    }

    private var mState = STATE_WAITING;

    // Page navigation index (0: GPS Lock Status, 1: Main Surf Page, 2: Diagnostics Page)
    private var mCurrentPage = 0;
    private const TOTAL_PAGES = 3;
    private var mGpsAccuracy = 0;

    // Wave statistics
    private var mTotalWaves = 0;
    private var mTotalSurfingTime = 0;
    private var mCurrentWaveDuration = 0;
    private var mLongestWaveDuration = 0;
    private var mMaxWaveSpeed = 0.0;
    private var mWaveRegistered = false;

    // Rolling buffer for accelerometer magnitude (5 seconds)
    private const BUFFER_SIZE = 5;
    private var mAccelBuffer = [1000.0, 1000.0, 1000.0, 1000.0, 1000.0];
    private var mBufferIndex = 0;
    private var mLastAccelMag = 1000.0;
    private var mCurrentVariance = 0.0;
    private var mHasAccelData = false;

    // Thresholds
    private const SURF_ACCEL_VAR_THRESHOLD = 5000.0; // millig^2
    private const SWEEP_SPEED_THRESHOLD = 2.5;     // 2.5 m/s = 9 km/h

    // Timer & Metrics
    private var mTimer;
    private var mSpeed = 0.0;
    private var mHeartRate = 0;

    function initialize() {
        View.initialize();

        mTimer = new Timer.Timer();

        // Register high-frequency accelerometer listener
        try {
            Sensor.registerSensorDataListener(method(:onAccelData), {
                :period => 1,
                :accelerometer => { :enabled => true }
            });
        } catch (e) {
            // Fallback for devices without sensor listener
        }
    }

    // Callback received when accelerometer sample batch is ready
    function onAccelData(sensorData as Sensor.SensorData) as Void {
        if (sensorData != null && sensorData.accelerometerData != null) {
            var x = sensorData.accelerometerData.x;
            var y = sensorData.accelerometerData.y;
            var z = sensorData.accelerometerData.z;
            if (x != null && y != null && z != null && x.size() > 0) {
                var maxMag = 0.0;
                for (var i = 0; i < x.size(); i++) {
                    var ax = x[i].toFloat();
                    var ay = y[i].toFloat();
                    var az = z[i].toFloat();
                    var mag = Math.sqrt(ax * ax + ay * ay + az * az);
                    if (mag > maxMag) {
                        maxMag = mag;
                    }
                }
                mLastAccelMag = maxMag;
                mHasAccelData = true;
            }
        }
    }

    function onShow() {
        mTimer.start(method(:onTimerTick), 1000, true);
        try {
            Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        } catch (e) {
        }
    }

    function onHide() {
        mTimer.stop();
        try {
            Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
        } catch (e) {
        }
    }

    function onPosition(info as Position.Info) as Void {
        if (info != null) {
            if (info.speed != null) {
                mSpeed = info.speed;
            }
            if (info.accuracy != null) {
                mGpsAccuracy = info.accuracy;
            }
        }
    }

    function onTimerTick() {
        compute();
        WatchUi.requestUpdate();
    }

    function nextPage() {
        mCurrentPage = (mCurrentPage + 1) % TOTAL_PAGES;
        WatchUi.requestUpdate();
    }

    function previousPage() {
        mCurrentPage = (mCurrentPage - 1 + TOTAL_PAGES) % TOTAL_PAGES;
        WatchUi.requestUpdate();
    }

    function compute() {
        try {
            var info = Activity.getActivityInfo();
            if (info != null) {
                if (info.currentSpeed != null) {
                    mSpeed = info.currentSpeed;
                } else {
                    mSpeed = 0.0;
                }
                if (info.currentHeartRate != null) {
                    mHeartRate = info.currentHeartRate;
                } else {
                    mHeartRate = 0;
                }
            }

            var accelMag = mLastAccelMag;
            var sensorInfo = Sensor.getInfo();
            if (sensorInfo != null && sensorInfo.accel != null) {
                var accel = sensorInfo.accel;
                if (accel != null && accel.size() >= 3) {
                    mHasAccelData = true;
                    var ax = accel[0].toFloat();
                    var ay = accel[1].toFloat();
                    var az = accel[2].toFloat();
                    var mag = Math.sqrt(ax * ax + ay * ay + az * az);
                    if (mag > accelMag) {
                        accelMag = mag;
                    }
                }
            }

            mAccelBuffer[mBufferIndex] = accelMag;
            mBufferIndex = (mBufferIndex + 1) % BUFFER_SIZE;

            var mean = 0.0;
            for (var i = 0; i < BUFFER_SIZE; i++) {
                mean += mAccelBuffer[i];
            }
            mean = mean / BUFFER_SIZE;

            var variance = 0.0;
            for (var i = 0; i < BUFFER_SIZE; i++) {
                var diff = mAccelBuffer[i] - mean;
                variance += diff * diff;
            }
            mCurrentVariance = variance / BUFFER_SIZE;

            // Only update wave state when active recording session is running
            if (mSession != null && mSession.isRecording()) {
                switch (mState) {
                    case STATE_WAITING:
                        if (mCurrentVariance > SURF_ACCEL_VAR_THRESHOLD && mSpeed < SWEEP_SPEED_THRESHOLD) {
                            mState = STATE_SURFING;
                            mCurrentWaveDuration = 0;
                            mWaveRegistered = false;
                        }
                        break;

                    case STATE_SURFING:
                        mCurrentWaveDuration += 1;

                        if (mSpeed > mMaxWaveSpeed) {
                            mMaxWaveSpeed = mSpeed;
                        }

                        if (mCurrentWaveDuration >= 3 && !mWaveRegistered) {
                            mTotalWaves += 1;
                            mWaveRegistered = true;
                        }

                        if (mWaveRegistered) {
                            mTotalSurfingTime += 1;
                        }

                        var endWave = false;
                        if (mSpeed >= SWEEP_SPEED_THRESHOLD) {
                            mState = STATE_SWEPT;
                            endWave = true;
                        } else if (mCurrentVariance <= SURF_ACCEL_VAR_THRESHOLD) {
                            mState = STATE_WAITING;
                            endWave = true;
                        }

                        if (endWave) {
                            if (mCurrentWaveDuration > mLongestWaveDuration) {
                                mLongestWaveDuration = mCurrentWaveDuration;
                            }
                            if (mWaveRegistered && mSession != null && mSession.isRecording()) {
                                mSession.addLap();
                            }
                        }
                        break;

                    case STATE_SWEPT:
                        if (mSpeed < SWEEP_SPEED_THRESHOLD) {
                            mState = STATE_WAITING;
                        }
                        break;
                }

                // Continuously sync active data to FIT fields during recording
                updateFitFields();
            } else {
                mState = STATE_WAITING;
            }
        } catch (e) {
            // Keep state intact
        }
    }

    // Explicitly update all FIT session & record fields
    private function updateFitFields() {
        if (mWaveCountField != null) {
            mWaveCountField.setData(mTotalWaves);
        }
        if (mTimeSurfingField != null) {
            mTimeSurfingField.setData(mTotalSurfingTime);
        }
        if (mMaxWaveSpeedField != null) {
            mMaxWaveSpeedField.setData(mMaxWaveSpeed);
        }
        if (mLongestWaveField != null) {
            mLongestWaveField.setData(mLongestWaveDuration);
        }
        if (mWaveDurationField != null) {
            var dur = (mState == STATE_SURFING) ? mCurrentWaveDuration : 0;
            mWaveDurationField.setData(dur);
        }
    }

    private var mMenuOpen = false;

    // Session Management & Menu Controls
    function onStartStopPressed() {
        if (mSession == null) {
            startSession();
            mCurrentPage = 1;
        } else if (mSession.isRecording()) {
            mSession.stop();
            showPauseMenu();
        } else {
            if (!mMenuOpen) {
                showPauseMenu();
            } else {
                resumeSession();
            }
        }
        WatchUi.requestUpdate();
    }

    function onBackPressed() {
        if (mSession != null) {
            if (mSession.isRecording()) {
                mSession.stop();
            }
            showPauseMenu();
            return true;
        }
        return false;
    }

    function toggleRecording() {
        onStartStopPressed();
    }

    function startSession() {
        if (mSession == null) {
            mSession = ActivityRecording.createSession({
                :name => "River Surfing",
                :sport => ActivityRecording.SPORT_SURFING,
                :subSport => ActivityRecording.SUB_SPORT_GENERIC
            });

            mWaveCountField = mSession.createField(
                "wave_count", 0, FitContributor.DATA_TYPE_UINT16,
                {
                    :mesgType => FitContributor.MESG_TYPE_SESSION,
                    :label => "Wave Count",
                    :units => "waves",
                    :count => 1,
                    :nativeNum => 26
                }
            );
            mTimeSurfingField = mSession.createField(
                "time_surfing", 1, FitContributor.DATA_TYPE_UINT32,
                {
                    :mesgType => FitContributor.MESG_TYPE_SESSION,
                    :label => "Surf Time",
                    :units => "s",
                    :count => 1
                }
            );
            mMaxWaveSpeedField = mSession.createField(
                "max_wave_speed", 2, FitContributor.DATA_TYPE_FLOAT,
                {
                    :mesgType => FitContributor.MESG_TYPE_SESSION,
                    :label => "Max Surf Speed",
                    :units => "m/s",
                    :count => 1
                }
            );
            mLongestWaveField = mSession.createField(
                "longest_wave_time", 3, FitContributor.DATA_TYPE_UINT16,
                {
                    :mesgType => FitContributor.MESG_TYPE_SESSION,
                    :label => "Longest Wave",
                    :units => "s",
                    :count => 1
                }
            );
            mWaveDurationField = mSession.createField(
                "wave_duration", 4, FitContributor.DATA_TYPE_UINT16,
                {
                    :mesgType => FitContributor.MESG_TYPE_RECORD,
                    :label => "Wave Duration",
                    :units => "s",
                    :count => 1
                }
            );

            mSession.start();
        } else if (!mSession.isRecording()) {
            mSession.start();
        }
        mMenuOpen = false;
        WatchUi.requestUpdate();
    }

    function resumeSession() {
        mMenuOpen = false;
        if (mSession != null && !mSession.isRecording()) {
            mSession.start();
        }
        WatchUi.requestUpdate();
    }

    function isRecording() {
        return mSession != null && mSession.isRecording();
    }

    function hasSession() {
        return mSession != null;
    }

    function saveSession() {
        mMenuOpen = false;
        if (mSession != null) {
            // Flush final FIT field values right before stopping and saving
            updateFitFields();

            if (mSession.isRecording()) {
                mSession.stop();
            }
            mSession.save();
            mSession = null;

            var summaryView = new RiverSurfSummaryView(mTotalWaves, mTotalSurfingTime, mLongestWaveDuration, mMaxWaveSpeed);
            var summaryDelegate = new RiverSurfSummaryDelegate();

            mTotalWaves = 0;
            mTotalSurfingTime = 0;
            mMaxWaveSpeed = 0.0;
            mLongestWaveDuration = 0;
            mState = STATE_WAITING;

            WatchUi.pushView(summaryView, summaryDelegate, WatchUi.SLIDE_IMMEDIATE);
        }
        WatchUi.requestUpdate();
    }

    function discardSession() {
        mMenuOpen = false;
        if (mSession != null) {
            if (mSession.isRecording()) {
                mSession.stop();
            }
            mSession.discard();
            mSession = null;
            mTotalWaves = 0;
            mTotalSurfingTime = 0;
            mMaxWaveSpeed = 0.0;
            mLongestWaveDuration = 0;
            mState = STATE_WAITING;
        }
        WatchUi.requestUpdate();
    }

    function showPauseMenu() {
        if (!mMenuOpen) {
            mMenuOpen = true;
            var menu = new WatchUi.Menu();
            menu.setTitle("Session Menu");
            menu.addItem("Resume", :itemResume);
            menu.addItem("Save", :itemSave);
            menu.addItem("Discard", :itemDiscard);

            WatchUi.pushView(menu, new RiverSurfMenuDelegate(self), WatchUi.SLIDE_IMMEDIATE);
        }
    }

    function onUpdate(dc) {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;
        var centerY = height / 2;
        var subCenterX = (width * 0.807).toNumber(); // 142 on 176px Instinct 2

        if (mCurrentPage == 0) {
            // ----------------------------------------------------
            // PAGE 1/3: GPS Lock & Satellite Status Page
            // ----------------------------------------------------
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.clear();
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

            // Top Header Flag
            var recLabel = (mSession != null && mSession.isRecording()) ? "[REC]" : "[READY]";
            dc.drawText((width * 0.057).toNumber(), (height * 0.136).toNumber(), Graphics.FONT_TINY, recLabel, Graphics.TEXT_JUSTIFY_LEFT);

            // Sub-Window Lens (Top-Right Circle): Live Speed
            dc.drawText(subCenterX, (height * 0.102).toNumber(), Graphics.FONT_XTINY, "KM/H", Graphics.TEXT_JUSTIFY_CENTER);
            var liveSpeedStr = (mSpeed * 3.6).format("%.1f");
            dc.drawText(subCenterX, (height * 0.238).toNumber(), Graphics.FONT_MEDIUM, liveSpeedStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // Main Center GPS Status Box
            var boxY = (height * 0.409).toNumber();
            var boxH = (height * 0.204).toNumber();

            if (mGpsAccuracy >= 3) { // 3: QUALITY_USABLE, 4: QUALITY_GOOD
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
                dc.fillRectangle(0, boxY, width, boxH);

                dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX, boxY + boxH / 2, Graphics.FONT_MEDIUM, "[ GPS READY ]", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX, (height * 0.67).toNumber(), Graphics.FONT_XTINY, "PRESS START TO SURF", Graphics.TEXT_JUSTIFY_CENTER);
            } else if (mGpsAccuracy == 2) { // 2: QUALITY_POOR (2D)
                dc.drawRectangle(10, boxY, width - 20, boxH);
                dc.drawText(centerX, boxY + boxH / 2, Graphics.FONT_TINY, "GPS POOR (2D)", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
                dc.drawText(centerX, (height * 0.67).toNumber(), Graphics.FONT_XTINY, "WAITING FOR 3D LOCK...", Graphics.TEXT_JUSTIFY_CENTER);
            } else {
                dc.drawRectangle(10, boxY, width - 20, boxH);
                dc.drawText(centerX, boxY + boxH / 2, Graphics.FONT_TINY, "SEARCHING GPS...", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
                dc.drawText(centerX, (height * 0.67).toNumber(), Graphics.FONT_XTINY, "LOOKING FOR SATELLITES", Graphics.TEXT_JUSTIFY_CENTER);
            }

            dc.drawText(centerX, (height * 0.84).toNumber(), Graphics.FONT_XTINY, "PAGE 1/3 (DN FOR SURF)", Graphics.TEXT_JUSTIFY_CENTER);

        } else if (mCurrentPage == 1) {
            // ----------------------------------------------------
            // PAGE 2/3: Primary Surf Activity Page
            // ----------------------------------------------------
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.clear();
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

            // Top-Left Header Zone
            var stateLabel = "[READY]";
            if (mSession != null && mSession.isRecording()) {
                stateLabel = "[REC]";
            }
            dc.drawText((width * 0.057).toNumber(), (height * 0.147).toNumber(), Graphics.FONT_TINY, stateLabel, Graphics.TEXT_JUSTIFY_LEFT);

            // Sub-Window Lens (Circle Lens in Top-Right)
            dc.drawText(subCenterX, (height * 0.113).toNumber(), Graphics.FONT_XTINY, "WAVES", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(subCenterX, (height * 0.25).toNumber(), Graphics.FONT_MEDIUM, mTotalWaves.toString(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // Main Status Banner (Center)
            var statusText = "[ WAITING ]";
            if (mState == STATE_SURFING) {
                statusText = "[ SURFING! ]";
            } else if (mState == STATE_SWEPT) {
                statusText = "[ SWEPT ]";
            }

            var bannerY = (height * 0.432).toNumber();
            var bannerH = (height * 0.193).toNumber();

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
            dc.fillRectangle(0, bannerY, width, bannerH);

            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, bannerY + bannerH / 2, Graphics.FONT_MEDIUM, statusText, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

            // Bottom Split Layout (Surf Time | Time of Day)
            var lineY1 = (height * 0.647).toNumber();
            var lineY2 = (height * 0.954).toNumber();
            dc.drawLine(centerX, lineY1, centerX, lineY2);

            var leftX = (width * 0.25).toNumber();
            var rightX = (width * 0.75).toNumber();

            dc.drawText(leftX, (height * 0.67).toNumber(), Graphics.FONT_XTINY, "SURF TIME", Graphics.TEXT_JUSTIFY_CENTER);
            
            var surfMins = mTotalSurfingTime / 60;
            var surfSecs = mTotalSurfingTime % 60;
            var surfTimeString = surfMins.format("%02d") + ":" + surfSecs.format("%02d");
            dc.drawText(leftX, (height * 0.784).toNumber(), Graphics.FONT_TINY, surfTimeString, Graphics.TEXT_JUSTIFY_CENTER);

            dc.drawText(rightX, (height * 0.67).toNumber(), Graphics.FONT_XTINY, "TOD", Graphics.TEXT_JUSTIFY_CENTER);

            var clockTime = System.getClockTime();
            var todString = clockTime.hour.format("%02d") + ":" + clockTime.min.format("%02d");
            dc.drawText(rightX, (height * 0.784).toNumber(), Graphics.FONT_TINY, todString, Graphics.TEXT_JUSTIFY_CENTER);

        } else if (mCurrentPage == 2) {
            // ----------------------------------------------------
            // PAGE 3/3: Sensor & Motion Diagnostics
            // ----------------------------------------------------
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.clear();
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

            dc.drawText(centerX, (height * 0.363).toNumber(), Graphics.FONT_XTINY, "DIAGNOSTICS", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            var accelStr = mHasAccelData ? "ACCEL: STREAMING (25Hz)" : "ACCEL: WAITING";
            dc.drawText(centerX, (height * 0.477).toNumber(), Graphics.FONT_XTINY, accelStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            var varStr = "CARVE VARIANCE: " + mCurrentVariance.format("%.0f");
            dc.drawText(centerX, (height * 0.59).toNumber(), Graphics.FONT_XTINY, varStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            var speedKmhStr = "GPS SPEED: " + (mSpeed * 3.6).format("%.1f") + " km/h";
            dc.drawText(centerX, (height * 0.704).toNumber(), Graphics.FONT_XTINY, speedKmhStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            var pageStr = "PAGE 3/3 (UP/DN SCROLL)";
            dc.drawText(centerX, (height * 0.806).toNumber(), Graphics.FONT_XTINY, pageStr, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }
}
