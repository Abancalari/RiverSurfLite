#!/usr/bin/env python3
"""
River Surfing FIT File Processor & Wave Analyzer
------------------------------------------------
Ingests Garmin .FIT files, analyzes wave riding sessions using RiverSurfLite criteria,
outputs processed .FIT files with corrected wave laps, summary metrics, and developer fields,
and provides FIT file merging capabilities ready for re-uploading to Garmin Connect.
"""

import sys
import os
import glob
import math
import argparse
import datetime
import io
import csv
from garmin_fit_sdk import Decoder, Encoder, Stream, Profile

# App ID and Developer Field Definitions matching RiverSurfLite (Connect IQ manifest.xml: a3536fc7-ba24-4f0f-8cbb-12948c264d1f)
RIVERSURF_APP_ID = [163, 83, 111, 199, 186, 36, 79, 15, 140, 187, 18, 148, 140, 38, 77, 31]

# Developer field definitions matching Connect IQ createField IDs:
# Field 0: wave_count (Session)
# Field 1: time_surfing (Session)
# Field 2: max_wave_speed (Session)
# Field 3: longest_wave_time (Session)
# Field 4: Surf State (Record timeline - overall state step plot)
# Field 5: Surfing Active (Record timeline - separate series color when riding wave)
# Field 6: Swept Cooldown (Record timeline - separate series color when swept downstream)
DEV_FIELD_DEFS = [
    {
        'field_name': 'Surf State',
        'units': 'state',
        'native_mesg_num': 20, # Record
        'developer_data_index': 0,
        'field_definition_number': 4,
        'fit_base_type_id': 0, # uint8
        'key': 0
    },
    {
        'field_name': 'wave_count',
        'units': 'waves',
        'native_mesg_num': 18, # Session
        'developer_data_index': 0,
        'field_definition_number': 0,
        'fit_base_type_id': 132, # uint16
        'native_field_num': 26,
        'key': 1
    },
    {
        'field_name': 'time_surfing',
        'units': 's',
        'native_mesg_num': 18, # Session
        'developer_data_index': 0,
        'field_definition_number': 1,
        'fit_base_type_id': 134, # uint32
        'key': 2
    },
    {
        'field_name': 'max_wave_speed',
        'units': 'm/s',
        'native_mesg_num': 18, # Session
        'developer_data_index': 0,
        'field_definition_number': 2,
        'fit_base_type_id': 136, # float32
        'key': 3
    },
    {
        'field_name': 'longest_wave_time',
        'units': 's',
        'native_mesg_num': 18, # Session
        'developer_data_index': 0,
        'field_definition_number': 3,
        'fit_base_type_id': 132, # uint16
        'key': 4
    },
    {
        'field_name': 'Surfing Active',
        'units': 'wave',
        'native_mesg_num': 20, # Record
        'developer_data_index': 0,
        'field_definition_number': 5,
        'fit_base_type_id': 0, # uint8
        'key': 5
    },
    {
        'field_name': 'Swept Cooldown',
        'units': 'swept',
        'native_mesg_num': 20, # Record
        'developer_data_index': 0,
        'field_definition_number': 6,
        'fit_base_type_id': 0, # uint8
        'key': 6
    }
]

DEV_DATA_ID_MESG = {
    'application_id': RIVERSURF_APP_ID,
    'application_version': 16,
    'developer_data_index': 0,
    'mesg_num': 207
}

NAME_TO_MESG_NUM = {
    'file_id_mesgs': 0,
    'file_creator_mesgs': 49,
    'developer_data_id_mesgs': 207,
    'field_description_mesgs': 206,
    'device_info_mesgs': 23,
    'device_settings_mesgs': 2,
    'user_profile_mesgs': 3,
    'zones_target_mesgs': 7,
    'sport_mesgs': 12,
    'event_mesgs': 21,
    'record_mesgs': 20,
    'gps_metadata_mesgs': 160,
    'lap_mesgs': 19,
    'session_mesgs': 18,
    'activity_mesgs': 34,
    'time_in_zone_mesgs': 216,
}

def calculate_distance(lat1_deg, lon1_deg, lat2_deg, lon2_deg):
    """Calculates Haversine distance in meters between two lat/lon degree coordinates."""
    if lat1_deg is None or lon1_deg is None or lat2_deg is None or lon2_deg is None:
        return 0.0
    lat1 = math.radians(lat1_deg)
    lon1 = math.radians(lon1_deg)
    lat2 = math.radians(lat2_deg)
    lon2 = math.radians(lon2_deg)
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = math.sin(dlat / 2.0)**2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2.0)**2
    c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))
    return 6371000.0 * c

def semicircles_to_degrees(sc):
    if sc is None:
        return None
    return sc * (180.0 / (2**31))

VALID_DEV_KEYS = {df['key'] for df in DEV_FIELD_DEFS}

def clean_message_dict(msg):
    cleaned = {}
    for k, v in msg.items():
        if v is None:
            continue
        if isinstance(v, float) and math.isnan(v):
            continue
        if k == 'developer_fields' and isinstance(v, dict):
            cleaned[k] = {dk: dv for dk, dv in v.items() if dk in VALID_DEV_KEYS and dv is not None}
        else:
            cleaned[k] = v
    return cleaned

def process_fit_file(filepath, output_filepath, min_surf_speed=0.4, surf_exit_speed=0.2,
                     sweep_speed=2.0, sweep_geofence_dist=25.0, min_wave_duration=5,
                     swept_cooldown=60, sport_type="surfing", export_csv=False):
    
    print(f"\n{'='*70}")
    print(f" PROCESSING FIT FILE: {os.path.basename(filepath)}")
    print(f"{'='*70}")
    print(f"Target Activity Type: {sport_type}")
    print(f"Criteria Thresholds:")
    print(f"  Min Surf Speed   : {min_surf_speed:.1f} m/s ({min_surf_speed*3.6:.1f} km/h)")
    print(f"  Surf Exit Speed  : {surf_exit_speed:.1f} m/s ({surf_exit_speed*3.6:.1f} km/h)")
    print(f"  Sweep Speed      : {sweep_speed:.1f} m/s ({sweep_speed*3.6:.1f} km/h)")
    print(f"  Geofence Distance: {sweep_geofence_dist:.1f} m")
    print(f"  Min Wave Duration: {min_wave_duration} s")
    print(f"  Swept Cooldown   : {swept_cooldown} s")

    stream = Stream.from_file(filepath)
    decoder = Decoder(stream)
    messages, errors = decoder.read()

    if errors:
        print(f"Warning: {len(errors)} decode warnings encountered.")

    record_mesgs = messages.get('record_mesgs', [])
    if not record_mesgs:
        print("Error: No record messages found in FIT file.")
        return False

    STATE_WAITING = 0
    STATE_SURFING = 1
    STATE_SURFED = 2
    STATE_SWEPT = 3

    state = STATE_WAITING
    swept_cooldown_ticks = 0
    surfed_display_ticks = 0

    total_waves = 0
    total_surfing_time = 0
    max_wave_speed = 0.0
    longest_wave_duration = 0

    current_wave_duration = 0
    current_wave_max_speed = 0.0
    wave_registered = False

    anchor_lat = None
    anchor_lon = None
    anchor_time = None
    wave_start_rec = None

    detected_waves = []
    processed_records = []
    recs_count = len(record_mesgs)
    # Calculate Session Wave Anchor (average of low-speed on-land/eddy points)
    waiting_lats = []
    waiting_lons = []
    for r in record_mesgs:
        spd = r.get('enhanced_speed') if r.get('enhanced_speed') is not None else (r.get('speed', 0.0) or 0.0)
        lat = semicircles_to_degrees(r.get('position_lat'))
        lon = semicircles_to_degrees(r.get('position_long'))
        if lat and lon and spd < 0.8:
            waiting_lats.append(lat)
            waiting_lons.append(lon)

    anchor_lat = sum(waiting_lats) / len(waiting_lats) if waiting_lats else None
    anchor_lon = sum(waiting_lons) / len(waiting_lons) if waiting_lons else None
    is_high_speed = [(r.get('enhanced_speed') if r.get('enhanced_speed') is not None else (r.get('speed', 0.0) or 0.0)) >= 1.0 for r in record_mesgs]
    is_surfing = [False] * recs_count
    is_swept = [False] * recs_count
    last_swept_exit_time = None

    for i in range(recs_count):
        curr_time = record_mesgs[i].get('timestamp')
        spd = record_mesgs[i].get('enhanced_speed') if record_mesgs[i].get('enhanced_speed') is not None else (record_mesgs[i].get('speed', 0.0) or 0.0)

        # Swept Cooldown: Must be at least swept_cooldown seconds after last swept exit before transitioning back into surf
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

    in_wave = False
    curr_wave_dur = 0
    wave_start_idx = 0
    wave_speeds = []

    # Determine Swept state (starts when exiting radius, ends when re-entering radius)
    in_swept_state = False
    for i in range(recs_count):
        plat = semicircles_to_degrees(record_mesgs[i].get('position_lat'))
        plon = semicircles_to_degrees(record_mesgs[i].get('position_long'))
        dist = calculate_distance(anchor_lat, anchor_lon, plat, plon) if (plat and plon) else None

        if dist is not None:
            if dist > sweep_geofence_dist:
                in_swept_state = True
            elif dist <= sweep_geofence_dist:
                in_swept_state = False

        if not is_surfing[i] and in_swept_state:
            is_swept[i] = True

    for i, rec in enumerate(record_mesgs):
        speed = rec.get('enhanced_speed') if rec.get('enhanced_speed') is not None else (rec.get('speed', 0.0) or 0.0)
        raw_lat = rec.get('position_lat')
        raw_lon = rec.get('position_long')
        lat_deg = semicircles_to_degrees(raw_lat)
        lon_deg = semicircles_to_degrees(raw_lon)
        timestamp = rec.get('timestamp')

        if is_surfing[i]:
            state = STATE_SURFING
        elif is_swept[i]:
            state = STATE_SWEPT
        else:
            state = STATE_WAITING

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
                    total_waves += 1
                    total_surfing_time += curr_wave_dur
                    start_r = record_mesgs[wave_start_idx]
                    end_r = record_mesgs[i - 1]
                    max_sp = max(wave_speeds) if wave_speeds else 0.0
                    avg_sp = sum(wave_speeds) / len(wave_speeds) if wave_speeds else 0.0
                    if curr_wave_dur > longest_wave_duration: longest_wave_duration = curr_wave_dur
                    if max_sp > max_wave_speed: max_wave_speed = max_sp

                    detected_waves.append({
                        'wave_num': total_waves,
                        'start_time': start_r.get('timestamp'),
                        'end_time': end_r.get('timestamp'),
                        'duration': curr_wave_dur,
                        'max_speed': max_sp,
                        'avg_speed': avg_sp,
                        'distance': 0.0,
                        'start_lat': start_r.get('position_lat'),
                        'start_lon': start_r.get('position_long'),
                        'end_lat': raw_lat,
                        'end_lon': raw_lon,
                    })
                in_wave = False
                curr_wave_dur = 0
                wave_speeds = []

        dev_state_val = 0
        if state == STATE_SURFING:
            dev_state_val = 1
        elif state == STATE_SWEPT:
            dev_state_val = 2

        rec_copy = dict(rec)
        dev_fields = rec_copy.get('developer_fields', {})
        if not isinstance(dev_fields, dict):
            dev_fields = {}

        dev_fields[0] = dev_state_val
        dev_fields[5] = 1 if dev_state_val == 1 else 0
        dev_fields[6] = 1 if dev_state_val == 2 else 0

        rec_copy['developer_fields'] = dev_fields
        processed_records.append(rec_copy)

    # Output Summary
    print(f"\nSURF SESSION METRICS SUMMARY:")
    print(f"  Total Waves Caught : {total_waves}")
    print(f"  Total Surfing Time : {total_surfing_time} s ({total_surfing_time//60}m {total_surfing_time%60}s)")
    print(f"  Max Surf Speed     : {max_wave_speed:.2f} m/s ({max_wave_speed * 3.6:.2f} km/h)")
    print(f"  Longest Wave       : {longest_wave_duration} s")

    if detected_waves:
        print(f"\nWAVE BREAKDOWN:")
        print(f"  {'#':<4} {'Start Time':<10} {'End Time':<10} {'Duration':<10} {'Max Speed':<16} {'Avg Speed':<16} {'Displacement':<12}")
        print(f"  {'-'*78}")
        for w in detected_waves:
            st_str = w['start_time'].strftime('%H:%M:%S') if isinstance(w['start_time'], datetime.datetime) else str(w['start_time'])
            et_str = w['end_time'].strftime('%H:%M:%S') if isinstance(w['end_time'], datetime.datetime) else str(w['end_time'])
            max_spd_str = f"{w['max_speed']:.2f} m/s ({w['max_speed']*3.6:.1f} km/h)"
            avg_spd_str = f"{w['avg_speed']:.2f} m/s ({w['avg_speed']*3.6:.1f} km/h)"
            print(f"  {w['wave_num']:<4} {st_str:<10} {et_str:<10} {w['duration']:<4}s       {max_spd_str:<16} {avg_spd_str:<16} {w['distance']:<6.1f} m")

    if export_csv:
        csv_filename = output_filepath.replace('.fit', '_waves.csv')
        with open(csv_filename, 'w', newline='') as cf:
            writer = csv.writer(cf)
            writer.writerow(['WaveNum', 'StartTime', 'EndTime', 'DurationSec', 'MaxSpeed_m_s', 'MaxSpeed_km_h', 'AvgSpeed_m_s', 'DisplacementMeters'])
            for w in detected_waves:
                writer.writerow([
                    w['wave_num'],
                    w['start_time'].isoformat() if hasattr(w['start_time'], 'isoformat') else str(w['start_time']),
                    w['end_time'].isoformat() if hasattr(w['end_time'], 'isoformat') else str(w['end_time']),
                    w['duration'],
                    f"{w['max_speed']:.3f}",
                    f"{w['max_speed']*3.6:.3f}",
                    f"{w['avg_speed']:.3f}",
                    f"{w['distance']:.2f}"
                ])
        print(f"\nExported wave breakdown CSV: {csv_filename}")

    # Re-encode FIT File
    encoder = Encoder()

    for df in DEV_FIELD_DEFS:
        encoder.add_developer_field(df['key'], DEV_DATA_ID_MESG, df)

    new_lap_mesgs = []
    new_split_mesgs = []
    for w in detected_waves:
        lap_msg = {
            'mesg_num': 19,
            'timestamp': w['end_time'],
            'start_time': w['start_time'],
            'total_timer_time': float(w['duration']),
            'total_elapsed_time': float(w['duration']),
            'enhanced_max_speed': float(w['max_speed']),
            'max_speed': float(w['max_speed']),
            'enhanced_avg_speed': float(w['avg_speed']),
            'avg_speed': float(w['avg_speed']),
            'total_distance': float(w['distance']),
            'start_position_lat': w['start_lat'],
            'start_position_long': w['start_lon'],
            'end_position_lat': w['end_lat'],
            'end_position_long': w['end_lon'],
            'event': 'lap',
            'event_type': 'stop',
            'sport': sport_type,
            'sub_sport': 'generic',
            'message_index': w['wave_num'] - 1
        }
        new_lap_mesgs.append(lap_msg)

        split_msg = {
            'mesg_num': 313,
            'message_index': w['wave_num'] - 1,
            'split_type': 'surf_active',
            'start_time': w['start_time'],
            'end_time': w['end_time'],
            'total_timer_time': float(w['duration']),
            'total_elapsed_time': float(w['duration']),
            'max_speed': float(w['max_speed']),
            'avg_speed': float(w['avg_speed']),
            'total_distance': float(w['distance']),
            'start_position_lat': w['start_lat'],
            'start_position_long': w['start_lon'],
            'end_position_lat': w['end_lat'],
            'end_position_long': w['end_lon'],
        }
        new_split_mesgs.append(split_msg)

    new_split_summary_mesg = {
        'mesg_num': 312,
        'message_index': 0,
        'split_type': 'surf_active',
        'num_splits': len(detected_waves),
        'total_timer_time': float(total_surfing_time),
        'max_speed': float(max_wave_speed),
        'avg_speed': float(sum(w['avg_speed'] for w in detected_waves) / len(detected_waves)) if detected_waves else 0.0,
        'total_distance': float(sum(w['distance'] for w in detected_waves))
    }

    for key, mesg_list in messages.items():
        mesg_num = None
        if key in NAME_TO_MESG_NUM:
            mesg_num = NAME_TO_MESG_NUM[key]
        elif key.isdigit():
            m_id = int(key)
            if m_id in Profile['messages']:
                mesg_num = m_id
            else:
                continue
        else:
            continue

        if key == 'developer_data_id_mesgs':
            encoder.write_mesg(DEV_DATA_ID_MESG)

        elif key == 'field_description_mesgs':
            for df in DEV_FIELD_DEFS:
                df_copy = clean_message_dict(df)
                df_copy['mesg_num'] = 206
                encoder.write_mesg(df_copy)

        elif key == 'sport_mesgs':
            for sm in mesg_list:
                sm_clean = clean_message_dict(sm)
                sm_clean['mesg_num'] = 12
                sm_clean['sport'] = sport_type
                sm_clean['sub_sport'] = 'generic'
                sm_clean['name'] = 'River Surfing'
                encoder.write_mesg(sm_clean)

        elif key == 'record_mesgs':
            for rec in processed_records:
                rec_clean = clean_message_dict(rec)
                rec_clean['mesg_num'] = 20
                encoder.write_mesg(rec_clean)

        elif key == 'lap_mesgs':
            if new_lap_mesgs:
                for lap in new_lap_mesgs:
                    lap_clean = clean_message_dict(lap)
                    lap_clean['developer_fields'] = {}
                    encoder.write_mesg(lap_clean)
            else:
                for lap in mesg_list:
                    lap_clean = clean_message_dict(lap)
                    lap_clean['mesg_num'] = 19
                    lap_clean['sport'] = sport_type
                    lap_clean['developer_fields'] = {}
                    encoder.write_mesg(lap_clean)

        elif key == 'session_mesgs':
            for sess in mesg_list:
                sess_clean = clean_message_dict(sess)
                sess_clean['mesg_num'] = 18
                sess_clean['sport'] = sport_type
                sess_clean['sub_sport'] = 'generic'
                sess_clean['sport_profile_name'] = 'River Surfing'
                sess_clean['num_laps'] = total_waves
                sess_clean['total_cycles'] = total_waves
                if max_wave_speed > 0:
                    sess_clean['enhanced_max_speed'] = max(sess_clean.get('enhanced_max_speed', 0.0), max_wave_speed)
                    sess_clean['max_speed'] = max(sess_clean.get('max_speed', 0.0), max_wave_speed)

                sess_clean['developer_fields'] = {
                    0: total_waves,
                    1: total_surfing_time,
                    2: float(max_wave_speed),
                    3: longest_wave_duration
                }

                encoder.write_mesg(sess_clean)

        else:
            if mesg_num is not None:
                for m in mesg_list:
                    m_clean = clean_message_dict(m)
                    m_clean['mesg_num'] = mesg_num
                    try:
                        encoder.write_mesg(m_clean)
                    except Exception as e:
                        pass

    out_bytes = encoder.close()
    with open(output_filepath, 'wb') as out_f:
        out_f.write(out_bytes)

    print(f"\nSUCCESS: Output file written to {output_filepath} ({len(out_bytes)} bytes)")
    return True

def merge_fit_files(file_paths, output_path, sport_type="surfing"):
    """Merges multiple chronological FIT files into a single unified FIT file."""
    print(f"\n{'='*70}")
    print(f" MERGING {len(file_paths)} FIT FILES INTO: {os.path.basename(output_path)}")
    print(f"{'='*70}")
    print(f"Target Activity Type: {sport_type}")

    all_decoded = []
    for path in file_paths:
        stream = Stream.from_file(path)
        decoder = Decoder(stream)
        messages, errors = decoder.read()
        all_decoded.append((path, messages))
        print(f"Loaded {os.path.basename(path)}: {len(messages.get('record_mesgs', []))} records, {len(messages.get('lap_mesgs', []))} laps.")

    def get_start_time(item):
        sess = item[1].get('session_mesgs', [{}])[0]
        return sess.get('start_time', datetime.datetime.min)

    all_decoded.sort(key=get_start_time)

    first_path, first_msgs = all_decoded[0]
    last_path, last_msgs = all_decoded[-1]

    merged_records = []
    merged_laps = []

    accumulated_distance_offset = 0.0
    total_waves = 0
    total_surfing_time = 0
    max_wave_speed = 0.0
    longest_wave_time = 0
    total_timer_time = 0.0
    total_elapsed_time = 0.0
    total_calories = 0
    overall_max_speed = 0.0

    lap_counter = 0

    for idx, (path, msgs) in enumerate(all_decoded):
        sess = msgs.get('session_mesgs', [{}])[0]
        timer_time = sess.get('total_timer_time', 0.0) or 0.0
        elapsed_time = sess.get('total_elapsed_time', 0.0) or 0.0
        cals = sess.get('total_calories', 0) or 0
        sess_max_spd = sess.get('enhanced_max_speed', 0.0) or sess.get('max_speed', 0.0) or 0.0

        total_timer_time += timer_time
        total_elapsed_time += elapsed_time
        total_calories += cals
        if sess_max_spd > overall_max_speed:
            overall_max_speed = sess_max_spd

        dev_fields = sess.get('developer_fields', {})
        if isinstance(dev_fields, dict):
            total_waves += dev_fields.get(1, 0)
            total_surfing_time += dev_fields.get(2, 0)
            max_wave_speed = max(max_wave_speed, dev_fields.get(3, 0.0))
            longest_wave_time = max(longest_wave_time, dev_fields.get(4, 0))

        recs = msgs.get('record_mesgs', [])
        for r in recs:
            r_copy = dict(r)
            dist = r_copy.get('distance')
            if dist is not None:
                r_copy['distance'] = dist + accumulated_distance_offset
            merged_records.append(r_copy)

        laps = msgs.get('lap_mesgs', [])
        for lap in laps:
            lap_copy = dict(lap)
            lap_copy['message_index'] = lap_counter
            lap_copy['sport'] = sport_type
            lap_counter += 1
            start_dist = lap_copy.get('start_distance')
            if start_dist is not None:
                lap_copy['start_distance'] = start_dist + accumulated_distance_offset
            merged_laps.append(lap_copy)

        accumulated_distance_offset += (recs[-1].get('distance', 0.0) if recs and recs[-1].get('distance') is not None else sess.get('total_distance', 0.0))

    first_sess = clean_message_dict(first_msgs.get('session_mesgs', [{}])[0])
    last_sess = clean_message_dict(last_msgs.get('session_mesgs', [{}])[0])

    merged_session = dict(first_sess)
    merged_session['mesg_num'] = 18
    merged_session['sport'] = sport_type
    merged_session['sub_sport'] = 'generic'
    merged_session['sport_profile_name'] = 'River Surfing'
    merged_session['timestamp'] = last_sess.get('timestamp')
    merged_session['total_timer_time'] = float(total_timer_time)
    merged_session['total_elapsed_time'] = float(total_elapsed_time)
    merged_session['total_distance'] = float(accumulated_distance_offset)
    merged_session['num_laps'] = lap_counter
    merged_session['total_cycles'] = total_waves
    merged_session['total_calories'] = total_calories
    merged_session['enhanced_max_speed'] = float(max(overall_max_speed, max_wave_speed))
    merged_session['max_speed'] = float(max(overall_max_speed, max_wave_speed))

    dev_fields = merged_session.get('developer_fields', {})
    if not isinstance(dev_fields, dict):
        dev_fields = {}
    dev_fields[1] = total_waves
    dev_fields[2] = total_surfing_time
    dev_fields[3] = float(max_wave_speed)
    dev_fields[4] = longest_wave_time
    merged_session['developer_fields'] = dev_fields

    first_act = clean_message_dict(first_msgs.get('activity_mesgs', [{}])[0])
    merged_activity = dict(first_act)
    merged_activity['mesg_num'] = 34
    merged_activity['timestamp'] = last_sess.get('timestamp')
    merged_activity['total_timer_time'] = float(total_timer_time)
    merged_activity['num_sessions'] = 1

    encoder = Encoder()
    for df in DEV_FIELD_DEFS:
        encoder.add_developer_field(df['key'], DEV_DATA_ID_MESG, df)

    encoder.write_mesg(DEV_DATA_ID_MESG)
    for df in DEV_FIELD_DEFS:
        df_c = clean_message_dict(df)
        df_c['mesg_num'] = 206
        encoder.write_mesg(df_c)

    for key in ['file_id_mesgs', 'file_creator_mesgs', 'device_settings_mesgs', 'user_profile_mesgs', 'zones_target_mesgs']:
        for m in first_msgs.get(key, []):
            m_c = clean_message_dict(m)
            m_c['mesg_num'] = NAME_TO_MESG_NUM[key]
            encoder.write_mesg(m_c)

    sport_m = clean_message_dict(first_msgs.get('sport_mesgs', [{}])[0])
    sport_m['mesg_num'] = 12
    sport_m['sport'] = sport_type
    sport_m['sub_sport'] = 'generic'
    sport_m['name'] = 'River Surfing'
    encoder.write_mesg(sport_m)

    for r in merged_records:
        r_c = clean_message_dict(r)
        r_c['mesg_num'] = 20
        encoder.write_mesg(r_c)

    for l in merged_laps:
        l_c = clean_message_dict(l)
        l_c['mesg_num'] = 19
        encoder.write_mesg(l_c)

    encoder.write_mesg(merged_session)
    encoder.write_mesg(merged_activity)

    out_bytes = encoder.close()
    with open(output_path, 'wb') as f:
        f.write(out_bytes)

    print(f"\nSUCCESSFULLY MERGED {len(file_paths)} FIT FILES!")
    print(f"  Merged File    : {output_path} ({len(out_bytes)} bytes)")
    print(f"  Sport Type     : {sport_type} (Profile: River Surfing)")
    print(f"  Total Waves    : {total_waves}")
    print(f"  Total Surf Time: {total_surfing_time} s ({total_surfing_time//60}m {total_surfing_time%60}s)")
    print(f"  Max Surf Speed : {max_wave_speed:.2f} m/s ({max_wave_speed*3.6:.2f} km/h)")
    print(f"  Longest Wave   : {longest_wave_time} s")
    print(f"  Total Distance : {accumulated_distance_offset:.1f} m")
    print(f"  Total Timer    : {total_timer_time:.1f} s ({total_timer_time/60:.1f} min)")
    print(f"  Total Wave Laps: {len(merged_laps)}")
    return True

def main():
    parser = argparse.ArgumentParser(
        description="Ingest Garmin .FIT files, analyze river surfing waves using RiverSurfLite criteria, and export processed/merged .FIT files for Garmin Connect."
    )
    parser.add_argument("files", nargs="+", help="Input .FIT file(s) or glob pattern (e.g. *.fit)")
    parser.add_argument("-m", "--merge", help="Merge all input files into a single specified FIT file (e.g. -m merged_session.fit)")
    parser.add_argument("-o", "--output-dir", help="Directory to save output files (default: same directory as input)")
    parser.add_argument("-s", "--suffix", default="_processed", help="Suffix for output filename (default: _processed)")
    parser.add_argument("--sport", default="surfing", choices=["surfing", "paddling", "stand_up_paddleboarding"], help="Activity sport type in FIT file (default: surfing)")
    parser.add_argument("--min-surf-speed", type=float, default=0.4, help="Minimum speed to trigger surf state in m/s (default: 0.4 = ~1.4 km/h)")
    parser.add_argument("--surf-exit-speed", type=float, default=0.2, help="Drop speed to exit wave in m/s (default: 0.2 = ~0.7 km/h)")
    parser.add_argument("--sweep-speed", type=float, default=2.0, help="Downstream sweep speed threshold in m/s (default: 2.0 = ~7.2 km/h)")
    parser.add_argument("--sweep-geofence", type=float, default=25.0, help="Geofence displacement threshold in meters (default: 25.0)")
    parser.add_argument("--min-wave-duration", type=int, default=5, help="Minimum wave duration in seconds (default: 5)")
    parser.add_argument("--swept-cooldown", type=int, default=60, help="Swept cooldown duration in seconds (default: 60)")
    parser.add_argument("--export-csv", action="store_true", help="Export wave breakdown to CSV")

    args = parser.parse_args()

    expanded_files = []
    for pattern in args.files:
        matches = glob.glob(pattern)
        if matches:
            expanded_files.extend(matches)
        else:
            expanded_files.append(pattern)

    if not expanded_files:
        print("Error: No FIT files specified.")
        sys.exit(1)

    if args.merge:
        processed_files = []
        for filepath in expanded_files:
            dir_name = args.output_dir if args.output_dir else os.path.dirname(filepath)
            base_name = os.path.splitext(os.path.basename(filepath))[0]
            out_filename = f"{base_name}{args.suffix}.fit"
            out_filepath = os.path.join(dir_name, out_filename)

            if filepath.endswith(f"{args.suffix}.fit"):
                processed_files.append(filepath)
            else:
                process_fit_file(
                    filepath=filepath,
                    output_filepath=out_filepath,
                    min_surf_speed=args.min_surf_speed,
                    surf_exit_speed=args.surf_exit_speed,
                    sweep_speed=args.sweep_speed,
                    sweep_geofence_dist=args.sweep_geofence,
                    min_wave_duration=args.min_wave_duration,
                    swept_cooldown=args.swept_cooldown,
                    sport_type=args.sport,
                    export_csv=args.export_csv
                )
                processed_files.append(out_filepath)

        merge_out = args.merge
        if not merge_out.endswith('.fit'):
            merge_out += '.fit'
        if args.output_dir and not os.path.isabs(merge_out):
            merge_out = os.path.join(args.output_dir, merge_out)

        merge_fit_files(processed_files, merge_out, sport_type=args.sport)

    else:
        for filepath in expanded_files:
            if not os.path.exists(filepath):
                print(f"Error: File not found: {filepath}")
                continue

            dir_name = args.output_dir if args.output_dir else os.path.dirname(filepath)
            base_name = os.path.splitext(os.path.basename(filepath))[0]
            out_filename = f"{base_name}{args.suffix}.fit"
            out_filepath = os.path.join(dir_name, out_filename)

            process_fit_file(
                filepath=filepath,
                output_filepath=out_filepath,
                min_surf_speed=args.min_surf_speed,
                surf_exit_speed=args.surf_exit_speed,
                sweep_speed=args.sweep_speed,
                sweep_geofence_dist=args.sweep_geofence,
                min_wave_duration=args.min_wave_duration,
                swept_cooldown=args.swept_cooldown,
                sport_type=args.sport,
                export_csv=args.export_csv
            )

if __name__ == "__main__":
    main()
