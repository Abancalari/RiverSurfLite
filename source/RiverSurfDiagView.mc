import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Timer;

class RiverSurfDiagView extends WatchUi.View {

    private var mParentView;
    private var mTimer;

    function initialize(parentView) {
        View.initialize();
        mParentView = parentView;
    }

    function onShow() {
        if (mTimer == null) {
            mTimer = new Timer.Timer();
        }
        mTimer.start(method(:onTimerTick), 1000, true);
    }

    function onHide() {
        if (mTimer != null) {
            mTimer.stop();
        }
    }

    function onTimerTick() {
        if (mParentView != null) {
            mParentView.compute();
        }
        WatchUi.requestUpdate();
    }

    function onLayout(dc) {
        setLayout(Rez.Layouts.DiagLayout(dc));
    }

    function onUpdate(dc) {
        if (mParentView != null) {
            var subGpsStatus = View.findDrawableById("SubGpsStatus") as Text;
            if (subGpsStatus != null) {
                subGpsStatus.setText(mParentView.getGpsAccuracy().toString());
            }

            var varianceVal = View.findDrawableById("VarianceValue") as Text;
            if (varianceVal != null) {
                varianceVal.setText(mParentView.getCarveVariance().format("%.0f"));
            }

            var speedVal = View.findDrawableById("GpsSpeedValue") as Text;
            if (speedVal != null) {
                speedVal.setText(mParentView.getSpeed().format("%.2f") + " m/s");
            }
        }

        View.onUpdate(dc);
    }
}

class RiverSurfDiagDelegate extends WatchUi.BehaviorDelegate {

    private var mParentView;

    function initialize(parentView) {
        BehaviorDelegate.initialize();
        mParentView = parentView;
    }

    function closeDiag() {
        if (mParentView != null) {
            mParentView.exitDiagnostics();
        }
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    function onSelect() {
        if (mParentView != null) {
            mParentView.showSettingsMenu();
        }
        return true;
    }

    function onBack() {
        return closeDiag();
    }

    function onPreviousPage() {
        return closeDiag();
    }

    function onNextPage() {
        return closeDiag();
    }
}
