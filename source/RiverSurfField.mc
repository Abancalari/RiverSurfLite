import Toybox.Application;
import Toybox.Graphics;
import Toybox.WatchUi;

class RiverSurfFieldApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
    }

    function onStop(state) {
    }

    function getInitialView() {
        return [new RiverSurfFieldView()];
    }

}

class RiverSurfFieldView extends WatchUi.WatchFace {

    function initialize() {
        WatchFace.initialize();
    }

    function onLayout(dc) {
        setLayout(Rez.Layouts.WatchFaceLayout(dc));
    }

    function onUpdate(dc) {
        // Update display
        View.onUpdate(dc);
    }

    function onPartialUpdate(dc) {
        // Partial screen updates for efficiency
    }

}

function getApp() {
    return Application.getApp();
}
