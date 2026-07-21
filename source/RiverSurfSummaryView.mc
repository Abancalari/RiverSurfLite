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

    function onUpdate(dc) {
        // Black background
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // Top Banner
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillRectangle(0, 10, 176, 28);

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(88, 24, Graphics.FONT_MEDIUM, "SURF SAVED", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        // 1. Total Waves
        dc.drawText(88, 44, Graphics.FONT_XTINY, "TOTAL WAVES", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(88, 62, Graphics.FONT_MEDIUM, mWaves.toString(), Graphics.TEXT_JUSTIFY_CENTER);

        // 2. Surf Time (Left)
        var mins = mSurfTime / 60;
        var secs = mSurfTime % 60;
        var timeStr = mins.format("%02d") + ":" + secs.format("%02d");
        dc.drawText(44, 96, Graphics.FONT_XTINY, "SURF TIME", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(44, 112, Graphics.FONT_TINY, timeStr, Graphics.TEXT_JUSTIFY_CENTER);

        // 3. Longest Wave (Right)
        dc.drawText(132, 96, Graphics.FONT_XTINY, "LONGEST", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(132, 112, Graphics.FONT_TINY, mLongestWave.toString() + "s", Graphics.TEXT_JUSTIFY_CENTER);

        // 4. Max Speed
        var speedKmh = (mMaxSpeed * 3.6).format("%.1f") + " km/h";
        dc.drawText(88, 134, Graphics.FONT_XTINY, "MAX: " + speedKmh, Graphics.TEXT_JUSTIFY_CENTER);

        // Footer hint
        dc.drawText(88, 154, Graphics.FONT_XTINY, "[ PRESS KEY TO EXIT ]", Graphics.TEXT_JUSTIFY_CENTER);
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
