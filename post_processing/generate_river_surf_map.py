#!/usr/bin/env python3
import sys
import os
import json
import datetime
from garmin_fit_sdk import Decoder, Stream
from process_river_surf import semicircles_to_degrees, calculate_distance

def generate_map_html(fit_filepath, output_html_path, sweep_geofence_dist=25.0, min_surf_speed=0.8):
    stream = Stream.from_file(fit_filepath)
    decoder = Decoder(stream)
    messages, _ = decoder.read()
    record_mesgs = messages.get('record_mesgs', [])

    recs_count = len(record_mesgs)

    is_high_speed = []
    for r in record_mesgs:
        spd = r.get('enhanced_speed') or r.get('speed', 0.0) or 0.0
        is_high_speed.append(spd >= 1.0)

    # Calculate Session Wave Spot Anchor
    waiting_lats = []
    waiting_lons = []
    for r in record_mesgs:
        spd = r.get('enhanced_speed') or r.get('speed', 0.0) or 0.0
        lat = semicircles_to_degrees(r.get('position_lat'))
        lon = semicircles_to_degrees(r.get('position_long'))
        if lat and lon and spd < min_surf_speed:
            waiting_lats.append(lat)
            waiting_lons.append(lon)

    anchor_lat = sum(waiting_lats) / len(waiting_lats) if waiting_lats else None
    anchor_lon = sum(waiting_lons) / len(waiting_lons) if waiting_lons else None

    is_surfing = [False] * recs_count
    is_swept = [False] * recs_count
    last_swept_exit_time = None

    swept_cooldown = 60

    for i in range(recs_count):
        curr_time = record_mesgs[i].get('timestamp')
        spd = record_mesgs[i].get('enhanced_speed') if record_mesgs[i].get('enhanced_speed') is not None else (record_mesgs[i].get('speed', 0.0) or 0.0)

        in_cooldown = False
        if last_swept_exit_time is not None and curr_time is not None:
            delta = (curr_time - last_swept_exit_time).total_seconds()
            if delta < swept_cooldown:
                in_cooldown = True

        if spd >= min_surf_speed and not is_surfing[i] and not in_cooldown:
            # Verify this speed spike burst eventually carries surfer outside the geofence
            leaves_zone = False
            for k in range(i, min(i + 90, recs_count)):
                plat = semicircles_to_degrees(record_mesgs[k].get('position_lat'))
                plon = semicircles_to_degrees(record_mesgs[k].get('position_long'))
                if plat and plon:
                    dist = calculate_distance(anchor_lat, anchor_lon, plat, plon) if (anchor_lat and plat) else 0.0
                    if dist > sweep_geofence_dist:
                        leaves_zone = True
                        break

            if leaves_zone:
                # Wave starts at speed spike (i) and ends when exiting the geofence (dist > sweep_geofence_dist)
                j = i
                while j < recs_count:
                    plat = semicircles_to_degrees(record_mesgs[j].get('position_lat'))
                    plon = semicircles_to_degrees(record_mesgs[j].get('position_long'))
                    dist = calculate_distance(anchor_lat, anchor_lon, plat, plon) if (plat and plon) else None
                    if dist is None or dist <= sweep_geofence_dist:
                        is_surfing[j] = True
                    else:
                        last_swept_exit_time = record_mesgs[j].get('timestamp')
                        break # Exited geofence zone!
                    j += 1

    # Bridge small gaps (< 5s) inside the 15m zone to form contiguous waves
    for i in range(1, recs_count - 1):
        if not is_surfing[i] and is_surfing[i-1]:
            for k in range(i + 1, min(i + 6, recs_count)):
                if is_surfing[k]:
                    for gap in range(i, k):
                        is_surfing[gap] = True
                    break

    # Build points & detected waves
    points = []
    waiting_lats = []
    waiting_lons = []

    detected_waves = []
    curr_wave_dur = 0
    in_wave = False
    wave_start_idx = 0
    wave_speeds = []

    STATE_WAITING = 0
    STATE_SURFING = 1
    STATE_SURFED = 2
    STATE_SWEPT = 3

    # Determine Swept state (starts when exiting radius, ends when re-entering radius)
    in_swept_state = False
    for i in range(recs_count):
        plat = semicircles_to_degrees(record_mesgs[i].get('position_lat'))
        plon = semicircles_to_degrees(record_mesgs[i].get('position_long'))
        dist = calculate_distance(anchor_lat, anchor_lon, plat, plon) if (anchor_lat and plat) else None

        if dist is not None:
            if dist > sweep_geofence_dist:
                in_swept_state = True
            elif dist <= sweep_geofence_dist:
                in_swept_state = False

        if not is_surfing[i] and in_swept_state:
            is_swept[i] = True

    for i, rec in enumerate(record_mesgs):
        speed = rec.get('enhanced_speed') or rec.get('speed', 0.0) or 0.0
        raw_lat = rec.get('position_lat')
        raw_lon = rec.get('position_long')
        timestamp = rec.get('timestamp')
        
        has_gps = (raw_lat is not None and raw_lon is not None)
        lat_deg = semicircles_to_degrees(raw_lat) if has_gps else None
        lon_deg = semicircles_to_degrees(raw_lon) if has_gps else None

        # Determine state for this record
        if is_surfing[i]:
            state = STATE_SURFING
        elif is_swept[i]:
            state = STATE_SWEPT
        else:
            state = STATE_WAITING
            if has_gps and speed < 0.8:
                waiting_lats.append(lat_deg)
                waiting_lons.append(lon_deg)

        # Track Wave Sessions
        if state == STATE_SURFING:
            if not in_wave:
                in_wave = True
                curr_wave_dur = 0
                wave_start_idx = i
                wave_speeds = [speed]
            else:
                curr_wave_dur += 1
                wave_speeds.append(speed)
        else:
            if in_wave:
                if curr_wave_dur >= 5:
                    start_r = record_mesgs[wave_start_idx]
                    end_r = record_mesgs[i - 1]
                    s_lat = semicircles_to_degrees(start_r.get('position_lat'))
                    s_lon = semicircles_to_degrees(start_r.get('position_long'))
                    e_lat = semicircles_to_degrees(end_r.get('position_lat'))
                    e_lon = semicircles_to_degrees(end_r.get('position_long'))
                    st_time = start_r.get('timestamp')
                    et_time = end_r.get('timestamp')

                    # Find valid lat/lon if start_r didn't have one
                    if s_lat is None:
                        for k_idx in range(wave_start_idx, i):
                            klat = semicircles_to_degrees(record_mesgs[k_idx].get('position_lat'))
                            klon = semicircles_to_degrees(record_mesgs[k_idx].get('position_long'))
                            if klat is not None:
                                s_lat, s_lon = klat, klon
                                break

                    if s_lat is not None:
                        avg_spd = sum(wave_speeds) / len(wave_speeds) if wave_speeds else 0.0
                        detected_waves.append({
                            'wave_num': len(detected_waves) + 1,
                            'start_time': st_time.strftime('%H:%M:%S') if isinstance(st_time, datetime.datetime) else str(st_time),
                            'end_time': et_time.strftime('%H:%M:%S') if isinstance(et_time, datetime.datetime) else str(et_time),
                            'duration': curr_wave_dur,
                            'max_speed': round(max(wave_speeds), 2) if wave_speeds else 0.0,
                            'max_speed_kmh': round(max(wave_speeds) * 3.6, 1) if wave_speeds else 0.0,
                            'avg_speed': round(avg_spd, 2),
                            'avg_speed_kmh': round(avg_spd * 3.6, 1),
                            'distance': round(calculate_distance(s_lat, s_lon, e_lat, e_lon), 1) if (s_lat and e_lat) else 0.0,
                            'start_lat': round(s_lat, 6),
                            'start_lon': round(s_lon, 6),
                            'end_lat': round(e_lat, 6) if e_lat else round(s_lat, 6),
                            'end_lon': round(e_lon, 6) if e_lon else round(s_lon, 6),
                        })
                in_wave = False
                curr_wave_dur = 0
                wave_speeds = []

        if has_gps:
            t_str = timestamp.strftime('%H:%M:%S') if isinstance(timestamp, datetime.datetime) else str(timestamp)
            points.append({
                'idx': len(points),
                'lat': round(lat_deg, 6),
                'lon': round(lon_deg, 6),
                'speed': round(speed, 2),
                'speed_kmh': round(speed * 3.6, 1),
                'state': state,
                'time': t_str,
                'wave_num': len(detected_waves) if state == STATE_SURFING else None
            })

    total_waves = len(detected_waves)
    total_surfing_time = sum(w['duration'] for w in detected_waves)
    max_wave_speed = max([w['max_speed'] for w in detected_waves], default=0.0)
    longest_wave_duration = max([w['duration'] for w in detected_waves], default=0)

    avg_onland_lat = sum(waiting_lats) / len(waiting_lats) if waiting_lats else 0.0
    avg_onland_lon = sum(waiting_lons) / len(waiting_lons) if waiting_lons else 0.0
    avg_onland_data = {
        'lat': round(avg_onland_lat, 6),
        'lon': round(avg_onland_lon, 6),
        'pts_count': len(waiting_lats)
    }

    for w in detected_waves:
        w['dist_from_avg_onland'] = round(calculate_distance(avg_onland_lat, avg_onland_lon, w['start_lat'], w['start_lon']), 1)

    # Build HTML content
    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>River Surfing Session Map - Standing Wave Model</title>
    <!-- Leaflet CSS & JS -->
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
    <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
    <!-- Google Fonts -->
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        * {{
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }}
        body {{
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
            background: #0f172a;
            color: #f8fafc;
            height: 100vh;
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }}
        header {{
            background: rgba(15, 23, 42, 0.95);
            backdrop-filter: blur(12px);
            border-bottom: 1px solid rgba(255, 255, 255, 0.1);
            padding: 12px 24px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            z-index: 1000;
        }}
        .header-title {{
            display: flex;
            align-items: center;
            gap: 12px;
        }}
        .header-title h1 {{
            font-size: 1.25rem;
            font-weight: 700;
            background: linear-gradient(135deg, #38bdf8, #34d399);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }}
        .badge {{
            background: rgba(56, 189, 248, 0.15);
            color: #38bdf8;
            border: 1px solid rgba(56, 189, 248, 0.3);
            font-size: 0.75rem;
            padding: 2px 8px;
            border-radius: 12px;
            font-weight: 600;
        }}
        .stats-summary {{
            display: flex;
            gap: 20px;
        }}
        .stat-item {{
            display: flex;
            flex-direction: column;
            align-items: flex-end;
        }}
        .stat-value {{
            font-size: 1.1rem;
            font-weight: 700;
            color: #f8fafc;
        }}
        .stat-label {{
            font-size: 0.7rem;
            color: #94a3b8;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }}
        #app-container {{
            flex: 1;
            display: flex;
            position: relative;
        }}
        #map {{
            flex: 1;
            height: 100%;
            width: 100%;
            background: #090d16;
        }}
        .panel {{
            position: absolute;
            top: 16px;
            right: 16px;
            width: 320px;
            background: rgba(15, 23, 42, 0.88);
            backdrop-filter: blur(16px);
            border: 1px solid rgba(255, 255, 255, 0.12);
            border-radius: 16px;
            padding: 16px;
            z-index: 1000;
            box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.5);
        }}
        .panel-title {{
            font-size: 0.9rem;
            font-weight: 600;
            color: #e2e8f0;
            margin-bottom: 12px;
            display: flex;
            align-items: center;
            justify-content: space-between;
        }}
        .legend-item {{
            display: flex;
            align-items: center;
            justify-content: space-between;
            margin-bottom: 8px;
            padding: 6px 10px;
            border-radius: 8px;
            background: rgba(255, 255, 255, 0.03);
            cursor: pointer;
            transition: all 0.2s ease;
        }}
        .legend-item:hover {{
            background: rgba(255, 255, 255, 0.08);
        }}
        .legend-left {{
            display: flex;
            align-items: center;
            gap: 10px;
            font-size: 0.85rem;
            font-weight: 500;
        }}
        .color-dot {{
            width: 12px;
            height: 12px;
            border-radius: 50%;
        }}
        .color-waiting {{ background: #38bdf8; box-shadow: 0 0 8px rgba(56, 189, 248, 0.5); }}
        .color-surfing {{ background: #10b981; box-shadow: 0 0 10px rgba(16, 185, 129, 0.8); }}
        .color-surfed {{ background: #f59e0b; box-shadow: 0 0 8px rgba(245, 158, 11, 0.5); }}
        .color-swept {{ background: #ef4444; box-shadow: 0 0 8px rgba(239, 68, 68, 0.5); }}
        .color-avg-anchor {{ background: #a855f7; box-shadow: 0 0 10px rgba(168, 85, 247, 0.9); }}

        .toggle-switch {{
            width: 32px;
            height: 18px;
            background: #334155;
            border-radius: 10px;
            position: relative;
            cursor: pointer;
            transition: background 0.2s;
        }}
        .toggle-switch.active {{
            background: #38bdf8;
        }}
        .toggle-switch::after {{
            content: '';
            position: absolute;
            top: 2px;
            left: 2px;
            width: 14px;
            height: 14px;
            border-radius: 50%;
            background: white;
            transition: transform 0.2s;
        }}
        .toggle-switch.active::after {{
            transform: translateX(14px);
        }}

        #timeline-container {{
            height: 160px;
            background: rgba(15, 23, 42, 0.95);
            border-top: 1px solid rgba(255, 255, 255, 0.1);
            padding: 12px 24px;
            z-index: 1000;
            display: flex;
            flex-direction: column;
        }}
        .timeline-header {{
            font-size: 0.78rem;
            font-weight: 600;
            color: #94a3b8;
            margin-bottom: 8px;
            display: flex;
            align-items: center;
            justify-content: space-between;
        }}
        .crop-status-badge {{
            color: #38bdf8;
            font-weight: 500;
            background: rgba(56, 189, 248, 0.1);
            border: 1px solid rgba(56, 189, 248, 0.25);
            padding: 2px 8px;
            border-radius: 6px;
        }}
        .btn-crop {{
            background: rgba(56, 189, 248, 0.15);
            color: #38bdf8;
            border: 1px solid rgba(56, 189, 248, 0.3);
            padding: 4px 10px;
            border-radius: 6px;
            font-size: 0.75rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s;
        }}
        .btn-crop:hover {{ background: rgba(56, 189, 248, 0.3); }}
        .btn-export {{
            background: rgba(16, 185, 129, 0.15);
            color: #10b981;
            border: 1px solid rgba(16, 185, 129, 0.3);
            padding: 4px 10px;
            border-radius: 6px;
            font-size: 0.75rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s;
            margin-left: 8px;
        }}
        .btn-export:hover {{ background: rgba(16, 185, 129, 0.3); }}

        .canvas-wrapper {{
            position: relative;
            flex: 1;
            width: 100%;
            display: flex;
            align-items: center;
        }}
        #chart-canvas {{
            width: 100%;
            height: 100%;
            cursor: crosshair;
        }}
        .crop-overlay {{
            position: absolute;
            top: 0;
            bottom: 0;
            background: rgba(15, 23, 42, 0.75);
            pointer-events: none;
            z-index: 10;
        }}
        #overlay-left {{ left: 0; width: 0%; border-right: 2px dashed #38bdf8; }}
        #overlay-right {{ right: 0; width: 0%; border-left: 2px dashed #38bdf8; }}

        .range-slider-container {{
            position: absolute;
            left: 0;
            right: 0;
            top: 0;
            bottom: 0;
            pointer-events: none;
            z-index: 20;
        }}
        input[type="range"] {{
            position: absolute;
            width: 100%;
            top: 50%;
            transform: translateY(-50%);
            pointer-events: none;
            -webkit-appearance: none;
            background: transparent;
        }}
        input[type="range"]::-webkit-slider-thumb {{
            pointer-events: auto;
            -webkit-appearance: none;
            width: 18px;
            height: 48px;
            border-radius: 6px;
            background: #38bdf8;
            border: 2px solid #ffffff;
            cursor: ew-resize;
            box-shadow: 0 0 12px rgba(56, 189, 248, 0.9);
        }}
        input[type="range"]::-moz-range-thumb {{
            pointer-events: auto;
            width: 18px;
            height: 48px;
            border-radius: 6px;
            background: #38bdf8;
            border: 2px solid #ffffff;
            cursor: ew-resize;
            box-shadow: 0 0 12px rgba(56, 189, 248, 0.9);
        }}

        /* Custom Leaflet Tooltips & Markers */
        .leaflet-popup-content-wrapper {{
            background: rgba(15, 23, 42, 0.95);
            color: #f8fafc;
            border: 1px solid rgba(255, 255, 255, 0.15);
            border-radius: 12px;
            box-shadow: 0 10px 25px rgba(0, 0, 0, 0.5);
            backdrop-filter: blur(8px);
        }}
        .leaflet-popup-tip {{
            background: rgba(15, 23, 42, 0.95);
        }}
        .wave-popup {{
            padding: 4px;
        }}
        .wave-popup h3 {{
            color: #10b981;
            font-size: 0.95rem;
            margin-bottom: 6px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.1);
            padding-bottom: 4px;
        }}
        .wave-popup-row {{
            display: flex;
            justify-content: space-between;
            font-size: 0.8rem;
            margin-bottom: 3px;
            color: #cbd5e1;
        }}
        .wave-badge-icon {{
            background: #10b981;
            color: white;
            font-weight: 700;
            font-size: 11px;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            box-shadow: 0 0 12px rgba(16, 185, 129, 0.9);
            border: 2px solid white;
        }}
        .anchor-badge-icon {{
            background: #a855f7;
            color: white;
            font-weight: 700;
            font-size: 11px;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            box-shadow: 0 0 16px rgba(168, 85, 247, 1);
            border: 2px solid white;
        }}
    </style>
</head>
<body>

    <header>
        <div class="header-title">
            <h1>River Surf Track & State Analysis</h1>
            <span class="badge">Standing Wave Model</span>
        </div>
        <div class="stats-summary">
            <div class="stat-item">
                <span class="stat-value" id="stat-waves" style="color: #10b981;">{total_waves}</span>
                <span class="stat-label">Waves Caught</span>
            </div>
            <div class="stat-item">
                <span class="stat-value" id="stat-surftime">{total_surfing_time}s</span>
                <span class="stat-label">Surf Time</span>
            </div>
            <div class="stat-item">
                <span class="stat-value" id="stat-maxspeed">{max_wave_speed*3.6:.1f} km/h</span>
                <span class="stat-label">Max Speed</span>
            </div>
            <div class="stat-item">
                <span class="stat-value" id="stat-longest">{longest_wave_duration}s</span>
                <span class="stat-label">Longest Wave</span>
            </div>
        </div>
    </header>

    <div id="app-container">
        <div id="map"></div>

        <div class="panel">
            <div class="panel-title">
                <span>State Layers & Filters</span>
            </div>
            <div class="legend-item" onclick="toggleState(0)">
                <div class="legend-left">
                    <div class="color-dot color-waiting"></div>
                    <span>Waiting / Paddling</span>
                </div>
                <div class="toggle-switch active" id="toggle-0"></div>
            </div>
            <div class="legend-item" onclick="toggleState(1)">
                <div class="legend-left">
                    <div class="color-dot color-surfing"></div>
                    <span>Standing Wave Riding</span>
                </div>
                <div class="toggle-switch active" id="toggle-1"></div>
            </div>
            <div class="legend-item" onclick="toggleState(3)">
                <div class="legend-left">
                    <div class="color-dot color-swept"></div>
                    <span>Swept Downstream Flush</span>
                </div>
                <div class="toggle-switch active" id="toggle-3"></div>
            </div>
            <div class="legend-item" onclick="toggleAvgOnland()">
                <div class="legend-left">
                    <div class="color-dot color-avg-anchor"></div>
                    <span>📍 Session Wave Anchor</span>
                </div>
                <div class="toggle-switch active" id="toggle-avg-onland"></div>
            </div>
        </div>
    </div>

    <div id="timeline-container">
        <div class="timeline-header">
            <div style="display:flex; align-items:center; gap:10px;">
                <span>Speed Profile & Timeline Crop Tool</span>
                <span class="crop-status-badge" id="crop-time-label">Showing Full Track (3,537 pts)</span>
            </div>
            <div style="display:flex; align-items:center; gap:8px;">
                <span id="hover-info" style="margin-right:12px;">Hover chart to inspect point</span>
                <button class="btn-crop" onclick="resetCrop()">Reset Crop</button>
                <button class="btn-export" onclick="exportCroppedCSV()">Export Cropped CSV</button>
            </div>
        </div>
        <div class="canvas-wrapper">
            <canvas id="chart-canvas"></canvas>
            <div class="crop-overlay" id="overlay-left"></div>
            <div class="crop-overlay" id="overlay-right"></div>
            <div class="range-slider-container">
                <input type="range" id="range-min" min="0" max="100" value="0" step="0.1" oninput="onCropChange()">
                <input type="range" id="range-max" min="0" max="100" value="100" step="0.1" oninput="onCropChange()">
            </div>
        </div>
    </div>

    <script>
        const rawPoints = {json.dumps(points)};
        const waveData = {json.dumps(detected_waves)};
        const avgOnlandData = {json.dumps(avg_onland_data)};

        const STATE_COLORS = {{
            0: '#38bdf8', // Waiting (Sky Blue - Inside Radius)
            1: '#10b981', // Standing Wave Surfing (Emerald Green)
            2: '#a855f7', // Transition
            3: '#f97316'  // Swept Downstream Flush (Vivid Amber-Orange)
        }};

        const STATE_NAMES = {{
            0: 'Waiting (Inside Radius)',
            1: 'Standing Wave Riding',
            2: 'Transition',
            3: 'Swept (Outside Radius)'
        }};

        const stateVisibility = {{ 0: true, 1: true, 2: true, 3: true }};
        let avgOnlandVisible = true;

        const map = L.map('map', {{
            zoomControl: false,
            maxZoom: 23
        }});

        L.control.zoom({{ position: 'bottomright' }}).addTo(map);

        const esriSatellite = L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{{z}}/{{y}}/{{x}}', {{
            maxNativeZoom: 19,
            maxZoom: 23,
            attribution: 'Tiles &copy; Esri'
        }}).addTo(map);

        const openStreetMap = L.tileLayer('https://{{s}}.tile.openstreetmap.org/{{z}}/{{y}}/{{x}}.png', {{
            maxNativeZoom: 19,
            maxZoom: 23,
            attribution: '&copy; OpenStreetMap'
        }});

        const baseMaps = {{
            "Satellite": esriSatellite,
            "Street Map": openStreetMap
        }};
        L.control.layers(baseMaps, null, {{ position: 'topleft' }}).addTo(map);

        const stateGroups = {{
            0: L.layerGroup().addTo(map),
            1: L.layerGroup().addTo(map),
            2: L.layerGroup().addTo(map),
            3: L.layerGroup().addTo(map)
        }};
        const waveMarkerGroup = L.layerGroup().addTo(map);
        const avgOnlandGroup = L.layerGroup().addTo(map);

        let hoverMarker = null;
        let cropMinIdx = 0;
        let cropMaxIdx = rawPoints.length - 1;

        function drawAvgOnlandOverlay() {{
            avgOnlandGroup.clearLayers();

            const lat = avgOnlandData.lat;
            const lon = avgOnlandData.lon;

            // Anchor Circle (Geofence Radius)
            L.circle([lat, lon], {{
                radius: {sweep_geofence_dist:.1f},
                color: '#a855f7',
                weight: 2,
                dashArray: '6, 6',
                fillColor: '#a855f7',
                fillOpacity: 0.15
            }}).addTo(avgOnlandGroup).bindPopup(`
                <div class="wave-popup">
                    <h3 style="color:#a855f7;">📍 Session Wave Spot Anchor</h3>
                    <div class="wave-popup-row"><span>Center:</span><strong>${{lat.toFixed(6)}}, ${{lon.toFixed(6)}}</strong></div>
                    <div class="wave-popup-row"><span>Radius:</span><strong>{sweep_geofence_dist:.1f}m Wave Spot Boundary</strong></div>
                </div>
            `);

            const icon = L.divIcon({{
                className: 'anchor-badge-icon',
                html: '📍',
                iconSize: [26, 26],
                iconAnchor: [13, 13]
            }});

            const marker = L.marker([lat, lon], {{ icon: icon }}).addTo(avgOnlandGroup);
            marker.bindPopup(`
                <div class="wave-popup">
                    <h3 style="color:#a855f7;">📍 Standing Wave Spot Anchor</h3>
                    <div class="wave-popup-row"><span>Lat:</span><strong>${{lat.toFixed(6)}}° N</strong></div>
                    <div class="wave-popup-row"><span>Lon:</span><strong>${{lon.toFixed(6)}}° W</strong></div>
                    <div class="wave-popup-row"><span>Model:</span><strong>Stationary Wave Riding</strong></div>
                </div>
            `);
        }}

        function renderCroppedMap() {{
            for (let s in stateGroups) stateGroups[s].clearLayers();
            waveMarkerGroup.clearLayers();

            const croppedPts = rawPoints.slice(cropMinIdx, cropMaxIdx + 1);
            if (croppedPts.length === 0) return;

            let currentSegment = [];
            let currentState = croppedPts[0].state;

            croppedPts.forEach((pt) => {{
                if (pt.state !== currentState) {{
                    if (currentSegment.length > 1) {{
                        drawSegment(currentSegment, currentState);
                    }}
                    currentSegment = [currentSegment[currentSegment.length - 1] || [pt.lat, pt.lon]];
                    currentState = pt.state;
                }}
                currentSegment.push([pt.lat, pt.lon]);
            }});
            if (currentSegment.length > 1) {{
                drawSegment(currentSegment, currentState);
            }}

            const startTimeStr = croppedPts[0].time;
            const endTimeStr = croppedPts[croppedPts.length - 1].time;

            const visibleWaves = waveData.filter(w => w.start_time >= startTimeStr && w.start_time <= endTimeStr);

            visibleWaves.forEach(w => {{
                const icon = L.divIcon({{
                    className: 'wave-badge-icon',
                    html: w.wave_num,
                    iconSize: [22, 22],
                    iconAnchor: [11, 11]
                }});

                const marker = L.marker([w.start_lat, w.start_lon], {{ icon: icon }}).addTo(waveMarkerGroup);
                marker.bindPopup(`
                    <div class="wave-popup">
                        <h3>🏄 Standing Wave Ride #${{w.wave_num}}</h3>
                        <div class="wave-popup-row"><span>Start Time:</span><strong>${{w.start_time}}</strong></div>
                        <div class="wave-popup-row"><span>End Time:</span><strong>${{w.end_time}}</strong></div>
                        <div class="wave-popup-row"><span>Ride Duration:</span><strong>${{w.duration}}s</strong></div>
                        <div class="wave-popup-row"><span>Status:</span><strong>Stationary Wave Ride</strong></div>
                    </div>
                `);
            }});

            document.getElementById('stat-waves').innerText = visibleWaves.length;
            
            let surfSecs = 0;
            let maxSpd = 0.0;
            let longestWv = 0;

            croppedPts.forEach(p => {{
                if (p.state === 1) surfSecs++;
                if (p.speed_kmh > maxSpd) maxSpd = p.speed_kmh;
            }});

            visibleWaves.forEach(w => {{
                if (w.duration > longestWv) longestWv = w.duration;
            }});

            document.getElementById('stat-surftime').innerText = `${{surfSecs}}s`;
            document.getElementById('stat-maxspeed').innerText = `${{maxSpd.toFixed(1)}} km/h`;
            document.getElementById('stat-longest').innerText = `${{longestWv}}s`;
        }}

        function drawSegment(coords, stateId) {{
            const weight = stateId === 1 ? 6 : (stateId === 3 ? 4.5 : 2.5);
            const opacity = stateId === 1 ? 0.95 : (stateId === 3 ? 0.90 : 0.45);

            const polyline = L.polyline(coords, {{
                color: STATE_COLORS[stateId],
                weight: weight,
                opacity: opacity,
                lineCap: 'round',
                lineJoin: 'round'
            }});
            polyline.addTo(stateGroups[stateId]);
        }}

        drawAvgOnlandOverlay();
        renderCroppedMap();
        if (rawPoints.length > 0) {{
            const allBounds = rawPoints.map(p => [p.lat, p.lon]);
            map.fitBounds(allBounds, {{ padding: [30, 30] }});
        }}

        function toggleState(stateId) {{
            stateVisibility[stateId] = !stateVisibility[stateId];
            const btn = document.getElementById(`toggle-${{stateId}}`);
            if (stateVisibility[stateId]) {{
                btn.classList.add('active');
                map.addLayer(stateGroups[stateId]);
            }} else {{
                btn.classList.remove('active');
                map.removeLayer(stateGroups[stateId]);
            }}
        }}

        function toggleAvgOnland() {{
            avgOnlandVisible = !avgOnlandVisible;
            const btn = document.getElementById('toggle-avg-onland');
            if (avgOnlandVisible) {{
                btn.classList.add('active');
                map.addLayer(avgOnlandGroup);
            }} else {{
                btn.classList.remove('active');
                map.removeLayer(avgOnlandGroup);
            }}
        }}

        function onCropChange() {{
            let minVal = parseFloat(document.getElementById('range-min').value);
            let maxVal = parseFloat(document.getElementById('range-max').value);

            if (minVal >= maxVal - 0.5) {{
                minVal = Math.max(0, maxVal - 0.5);
                document.getElementById('range-min').value = minVal;
            }}

            const pctMin = minVal / 100;
            const pctMax = maxVal / 100;

            cropMinIdx = Math.floor(pctMin * (rawPoints.length - 1));
            cropMaxIdx = Math.floor(pctMax * (rawPoints.length - 1));

            document.getElementById('overlay-left').style.width = (pctMin * 100) + '%';
            document.getElementById('overlay-right').style.width = ((1 - pctMax) * 100) + '%';

            const tStart = rawPoints[cropMinIdx].time;
            const tEnd = rawPoints[cropMaxIdx].time;
            const count = cropMaxIdx - cropMinIdx + 1;

            document.getElementById('crop-time-label').innerText = `Cropped: ${{tStart}} → ${{tEnd}} (${{count}} pts)`;

            renderCroppedMap();
        }}

        function resetCrop() {{
            document.getElementById('range-min').value = 0;
            document.getElementById('range-max').value = 100;
            onCropChange();
            if (rawPoints.length > 0) {{
                const allBounds = rawPoints.map(p => [p.lat, p.lon]);
                map.fitBounds(allBounds, {{ padding: [30, 30] }});
            }}
        }}

        function exportCroppedCSV() {{
            const croppedPts = rawPoints.slice(cropMinIdx, cropMaxIdx + 1);
            let csvContent = "data:text/csv;charset=utf-8,Index,Time,Latitude,Longitude,Speed_m_s,Speed_km_h,SurfState,StateName\\n";

            croppedPts.forEach(p => {{
                csvContent += `${{p.idx}},${{p.time}},${{p.lat}},${{p.lon}},${{p.speed}},${{p.speed_kmh}},${{p.state}},"${{STATE_NAMES[p.state]}}"\\n`;
            }});

            const encodedUri = encodeURI(csvContent);
            const link = document.createElement("a");
            link.setAttribute("href", encodedUri);
            link.setAttribute("download", `river_surf_cropped_${{rawPoints[cropMinIdx].time.replace(/:/g,'')}}_${{rawPoints[cropMaxIdx].time.replace(/:/g,'')}}.csv`);
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);
        }}

        const canvas = document.getElementById('chart-canvas');
        const ctx = canvas.getContext('2d');

        function resizeCanvas() {{
            canvas.width = canvas.clientWidth * window.devicePixelRatio;
            canvas.height = canvas.clientHeight * window.devicePixelRatio;
            drawChart();
        }}
        window.addEventListener('resize', resizeCanvas);
        setTimeout(resizeCanvas, 100);

        function drawChart() {{
            if (!canvas.width || !canvas.height) return;
            const w = canvas.width;
            const h = canvas.height;

            ctx.clearRect(0, 0, w, h);

            const maxSpd = Math.max(...rawPoints.map(p => p.speed_kmh), 8.0);
            const n = rawPoints.length;

            for (let i = 0; i < n - 1; i++) {{
                const x1 = (i / n) * w;
                const x2 = ((i + 1) / n) * w;
                const stateId = rawPoints[i].state;
                ctx.fillStyle = STATE_COLORS[stateId];
                ctx.globalAlpha = stateId === 1 ? 0.45 : (stateId === 3 ? 0.45 : 0.08);
                ctx.fillRect(x1, 0, x2 - x1, h);
            }}

            ctx.globalAlpha = 1.0;
            ctx.beginPath();
            ctx.strokeStyle = '#38bdf8';
            ctx.lineWidth = 1.5 * window.devicePixelRatio;

            rawPoints.forEach((p, i) => {{
                const x = (i / n) * w;
                const y = h - (p.speed_kmh / maxSpd) * (h - 20) - 10;
                if (i === 0) ctx.moveTo(x, y);
                else ctx.lineTo(x, y);
            }});
            ctx.stroke();
        }}

        canvas.addEventListener('mousemove', (e) => {{
            const rect = canvas.getBoundingClientRect();
            const mouseX = e.clientX - rect.left;
            const pct = mouseX / rect.width;
            const idx = Math.min(Math.max(0, Math.floor(pct * rawPoints.length)), rawPoints.length - 1);
            const pt = rawPoints[idx];

            document.getElementById('hover-info').innerHTML = 
                `<strong>${{pt.time}}</strong> | State: <span style="color:${{STATE_COLORS[pt.state]}}">${{STATE_NAMES[pt.state]}}</span> | Speed: <strong>${{pt.speed_kmh}} km/h</strong>`;

            if (!hoverMarker) {{
                hoverMarker = L.circleMarker([pt.lat, pt.lon], {{
                    radius: 7,
                    color: '#ffffff',
                    fillColor: STATE_COLORS[pt.state],
                    fillOpacity: 1.0,
                    weight: 2
                }}).addTo(map);
            }} else {{
                hoverMarker.setLatLng([pt.lat, pt.lon]);
                hoverMarker.setStyle({{ fillColor: STATE_COLORS[pt.state] }});
            }}
        }});
    </script>
</body>
</html>
"""

    with open(output_html_path, 'w', encoding='utf-8') as f:
        f.write(html_content)

    print(f"Generated map HTML with Standing Wave Model: {output_html_path}")

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description="Generate Standing Wave Map HTML")
    parser.add_argument("fit_filepath", help="Path to raw/processed FIT file")
    parser.add_argument("output_html_path", nargs="?", default=None, help="Output HTML map filepath")
    parser.add_argument("--sweep-geofence", type=float, default=25.0, help="Geofence radius threshold in meters (default: 25.0)")
    parser.add_argument("--min-surf-speed", type=float, default=0.8, help="Minimum speed threshold in m/s (default: 0.8)")

    args = parser.parse_args()
    fit_path = args.fit_filepath
    out_html = args.output_html_path
    if not out_html:
        base_name = os.path.splitext(os.path.basename(fit_path))[0].split('_')[0]
        out_html = f"river_surf_map_{base_name}.html"

    generate_map_html(fit_path, out_html, sweep_geofence_dist=args.sweep_geofence, min_surf_speed=args.min_surf_speed)
