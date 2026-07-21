import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.System;

class RiverSurfSummaryView extends WatchUi.View {

    private var mWaves;
    private var mSurfTime;
    private var mLongestWave;
    private var mMaxSpeed;

    function initialize(waves, surfTime, longestWave, maxSpeed) {
        View.initialize();
        mWaves = waves;
        mSurfTime = surfTime;
        mLongestWave = longestWave;
        mMaxSpeed = maxSpeed;
    }

    function onLayout(dc) {
        setLayout(Rez.Layouts.SummaryLayout(dc));
    }

    function onUpdate(dc) {
        var wavesLabel = View.findDrawableById("TotalWaves") as Text;
        if (wavesLabel != null) {
            wavesLabel.setText(mWaves.toString());
        }

        var timeLabel = View.findDrawableById("SurfTime") as Text;
        if (timeLabel != null) {
            var mins = mSurfTime / 60;
            var secs = mSurfTime % 60;
            timeLabel.setText(mins.format("%02d") + ":" + secs.format("%02d"));
        }

        var longestLabel = View.findDrawableById("LongestWave") as Text;
        if (longestLabel != null) {
            longestLabel.setText(mLongestWave.toString() + "s");
        }

        var maxSpeedLabel = View.findDrawableById("MaxSpeed") as Text;
        if (maxSpeedLabel != null) {
            maxSpeedLabel.setText("MAX: " + (mMaxSpeed * 3.6).format("%.1f") + " km/h");
        }

        View.onUpdate(dc);
    }
}

class RiverSurfSummaryDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onSelect() {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    function onBack() {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    function onPreviousPage() {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    function onNextPage() {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }
}
