import Toybox.WatchUi;
import Toybox.Graphics;

class RiverSurfDiagView extends WatchUi.View {

    private var mParentView;

    function initialize(parentView) {
        View.initialize();
        mParentView = parentView;
    }

    function onLayout(dc) {
        setLayout(Rez.Layouts.DiagLayout(dc));
    }

    function onUpdate(dc) {
        if (mParentView != null) {
            var accelStatus = View.findDrawableById("AccelStatus") as Text;
            if (accelStatus != null) {
                accelStatus.setText(mParentView.hasAccelData() ? "ACCEL: STREAMING (25Hz)" : "ACCEL: WAITING");
            }

            var varianceText = View.findDrawableById("VarianceText") as Text;
            if (varianceText != null) {
                varianceText.setText("CARVE VARIANCE: " + mParentView.getCarveVariance().format("%.0f"));
            }

            var gpsSpeedText = View.findDrawableById("GpsSpeedText") as Text;
            if (gpsSpeedText != null) {
                gpsSpeedText.setText("GPS SPEED: " + (mParentView.getSpeed() * 3.6).format("%.1f") + " km/h");
            }
        }

        View.onUpdate(dc);
    }
}

class RiverSurfDiagDelegate extends WatchUi.BehaviorDelegate {

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
