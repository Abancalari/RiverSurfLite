import Toybox.Application;
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
        return [ new RiverSurfView() ];
    }

}

function getApp() {
    return Application.getApp();
}
