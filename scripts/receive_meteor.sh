#!/bin/bash
#
# Purpose: Receive and process Meteor-M 2 captures.
#
# Input parameters:
#   1. Name of satellite "METEOR-M 2"
#   2. Filename of image outputs
#   3. TLE file location
#   4. Duration of capture (seconds)
#   5. Max angle elevation for satellite
#   6. Direction of pass
#   7. Side of pass (W=West, E=East) relative to base station
#
# Example:
#   ./receive_meteor.sh "METEOR-M 2" METEOR-M220210205-192623 1612571183 922 39 Northbound W

# time keeping
TIMER_START=$(date '+%s')

# import common lib and settings
. "$HOME/.noaa-v2.conf"
. "$NOAA_HOME/scripts/common.sh"
capture_start=$START_DATE

# input params
export SAT_NAME=$1
export FILENAME_BASE=$2
export TLE_FILE=$3
export EPOCH_START=$4
export CAPTURE_TIME=$5
export SAT_MAX_ELEVATION=$6
export PASS_DIRECTION=$7
export PASS_SIDE=$8

# export some variables for use in the annotation - note that we do not
# want to export all of .noaa-v2.conf because it contains sensitive info
export GAIN=$METEOR_M2_GAIN
export SUN_MIN_ELEV=$METEOR_M2_SUN_MIN_ELEV
export SDR_DEVICE_ID=$METEOR_M2_SDR_DEVICE_ID
export BIAS_TEE=$METEOR_M2_ENABLE_BIAS_TEE
export FREQ_OFFSET=$METEOR_M2_FREQ_OFFSET
export SAT_MIN_ELEV=$METEOR_M2_SAT_MIN_ELEV

# base directory plus filename_base for re-use
RAMFS_AUDIO_BASE="${RAMFS_AUDIO}/${FILENAME_BASE}"
AUDIO_FILE_BASE="${METEOR_AUDIO_OUTPUT}/${FILENAME_BASE}"
IMAGE_FILE_BASE="${IMAGE_OUTPUT}/${FILENAME_BASE}"
IMAGE_THUMB_BASE="${IMAGE_OUTPUT}/thumb/${FILENAME_BASE}"

case "$RECEIVER_TYPE" in
    "rtlsdr")
        samplerate="1.024e6"
        receiver="rtlsdr"
        ;;
    "airspy_mini")
        samplerate="3e6"
        receiver="airspy"
        ;;
    "airspy_r2")
        samplerate="2.5e6"
        receiver="airspy"
        ;;
    "hackrf")
        samplerate="4e6"
        receiver="hackrf"
        ;;
    *)
        echo "Invalid RECEIVER_TYPE value: $RECEIVER_TYPE"
        exit 1
        ;;
esac

# check if there is enough free memory to store pass on RAM
FREE_MEMORY=$(free -m | grep Mem | awk '{print $7}')
if [ "$FREE_MEMORY" -lt $METEOR_M2_MEMORY_TRESHOLD ]; then
  log "The system doesn't have enough space to store a Meteor pass on RAM" "INFO"
  log "Free : ${FREE_MEMORY} ; Required : ${METEOR_M2_MEMORY_TRESHOLD}" "INFO"
  RAMFS_AUDIO_BASE="${METEOR_AUDIO_OUTPUT}/${FILENAME_BASE}"
  in_mem=false
else
  log "The system have enough space to store a Meteor pass on RAM" "INFO"
  log "Free : ${FREE_MEMORY} ; Required : ${METEOR_M2_MEMORY_TRESHOLD}" "INFO"
  in_mem=true
fi

FLIP=""
log "Direction $PASS_DIRECTION" "INFO"
if [ "$PASS_DIRECTION" == "Northbound" ] && [ "$FLIP_METEOR_IMG" == "true" ]; then
  log "I'll flip this image pass because FLIP_METEOR_IMG is set to true and PASS_DIRECTION is Northbound" "INFO"
  FLIP="-rotate 180"
fi

# pass start timestamp and sun elevation
PASS_START=$(expr "$EPOCH_START" + 90)
export SUN_ELEV=$(python3 "$SCRIPTS_DIR"/tools/sun.py "$PASS_START")

# determine if pass is in daylight
daylight=0
if [ "${SUN_ELEV}" -gt "${SUN_MIN_ELEV}" ]; then daylight=1; fi

# always kill running captures for NOAA in favor of capture
# for Meteor, no matter which receive method is being used, in order
# to avoid resource contention and/or signal interference
# First check for rtl_fm mode active instances
if pgrep "rtl_fm" > /dev/null; then
  log "There is an already running rtl_fm noaa capture instance but I dont care for now, I prefer this pass" "INFO"
  pkill -9 -f rtl_fm
fi
# then for gnuradio mode active instances
if pgrep -f ${RECEIVER_TYPE}_noaa_apt_rx.py > /dev/null; then
  log "There is an already running gnuradio noaa capture instance but I dont care for now, I prefer this pass" "INFO"
  kill $(pgrep -f ${RECEIVER_TYPE}_noaa_apt_rx.py)
fi
if pgrep "satdump" > /dev/null; then
  log "There is an already running satdump noaa capture instance but I dont care for now, I prefer this pass" "INFO"
  pkill -9 -f satdump
fi

# determine if auto-gain is set - handles "0" and "0.0" floats
gain=$GAIN
if [ $(echo "$GAIN==0"|bc) -eq 1 ]; then
  gain='Automatic'
fi

# create push annotation string (annotation in the email subject, discord text, etc.)
# note this is NOT the annotation on the image, which is driven by the config/annotation/annotation.html.j2 file
push_annotation=""
if [ "${GROUND_STATION_LOCATION}" != "" ]; then
  push_annotation="Ground Station: ${GROUND_STATION_LOCATION}\n"
fi
push_annotation="${push_annotation}${SAT_NAME} ${capture_start}"
push_annotation="${push_annotation} Max Elev: ${SAT_MAX_ELEVATION}° ${PASS_SIDE}"
push_annotation="${push_annotation} Sun Elevation: ${SUN_ELEV}°"
push_annotation="${push_annotation} Gain: ${gain}"
push_annotation="${push_annotation} | ${PASS_DIRECTION}"

# TODO: Fix this up - this conditional selection is a massive bit of complexity that
#       needs to be handled, but in the interest of not breaking everything (at least in
#       the first round), keeping it simple.
push_file_list=""
spectrogram=0
polar_az_el=0
polar_direction=0

if [ "$METEOR_RECEIVER" == "rtl_fm" ]; then
  log "Starting rtl_fm record" "INFO"
  ${AUDIO_PROC_DIR}/meteor_record_rtl_fm.sh $CAPTURE_TIME "${RAMFS_AUDIO_BASE}.wav" >> $NOAA_LOG 2>&1

  sleep 2

  if [[ "${PRODUCE_SPECTROGRAM}" == "true" ]]; then
    log "Producing spectrogram" "INFO"
    spectrogram=1
    spectro_text="${capture_start} @ ${SAT_MAX_ELEVATION}°"
    ${IMAGE_PROC_DIR}/spectrogram.sh "${RAMFS_AUDIO_BASE}.wav" "${IMAGE_FILE_BASE}-spectrogram.png" "${SAT_NAME}" "${spectro_text}" >> $NOAA_LOG 2>&1
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "${IMAGE_FILE_BASE}-spectrogram.png" "${IMAGE_THUMB_BASE}-spectrogram.png" >> $NOAA_LOG 2>&1
  fi

  log "Running MeteorDemod to demodulate OQPSK file, rectify (spread) images, create heat map and composites and convert them to JPG" "INFO"
  if [[ "$METEOR_80K_INTERLEAVING" == "true" ]]; then
    $METEORDEMOD -m oqpsk -diff 1 -int 1 -s 80000 -sat METEOR-M-2-3 -t "$TLE_FILE" -f jpg -i "${RAMFS_AUDIO_BASE}.wav" >> $NOAA_LOG 2>&1
  else
    $METEORDEMOD -m oqpsk -diff 1 -s 72000 -sat METEOR-M-2-3 -t "$TLE_FILE" -f jpg -i "${RAMFS_AUDIO_BASE}.wav" >> $NOAA_LOG 2>&1
  fi

  rm *.gcp *.bmp "${RAMFS_AUDIO_BASE}.wav"

  sleep 2

  for i in spread_*.jpg
  do
    $CONVERT -quality 100 $FLIP "$i" "$i" >> $NOAA_LOG 2>&1
  done

  for file in *.jpg; do
    new_filename=$(echo "$file" | sed -E 's/_[0-9]+-[0-9]+-[0-9]+-[0-9]+-[0-9]+-[0-9]+\.jpg$/.jpg/')
    mv "$file" "$new_filename"

    ${IMAGE_PROC_DIR}/meteor_normalize_annotate.sh "$new_filename" "$new_filename" $METEOR_IMAGE_QUALITY >> $NOAA_LOG 2>&1
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "$new_filename" "${new_filename%.jpg}-thumb.jpg" >> $NOAA_LOG 2>&1
    mv "$new_filename" "${IMAGE_FILE_BASE}-${new_filename%.jpg}.jpg"
    mv "${new_filename%.jpg}-thumb.jpg" "${IMAGE_THUMB_BASE}-${new_filename%.jpg}.jpg"
    push_file_list="$push_file_list ${IMAGE_FILE_BASE}-${new_filename%.jpg}.jpg "
  done

  if [ "$DELETE_AUDIO" = true ]; then
    log "Deleting audio files" "INFO"
    rm "${RAMFS_AUDIO_BASE}.s"
  else
    if [ "$in_mem" == "true" ]; then
      log "Moving audio files out to the SD card" "INFO"
      mv "${RAMFS_AUDIO_BASE}.s" "${AUDIO_FILE_BASE}.s"
    fi
  fi
elif [ "$METEOR_RECEIVER" == "gnuradio" ]; then

  log "Starting gnuradio record" "INFO"
  ${AUDIO_PROC_DIR}/meteor_record_gnuradio.sh $CAPTURE_TIME "${RAMFS_AUDIO_BASE}.wav" >> $NOAA_LOG 2>&1

  log "Waiting for files to close" "INFO"
  sleep 2

  log "Running MeteorDemod to demodulate OQPSK file, rectify (spread) images, create heat map and composites and convert them to JPG" "INFO"
  if [[ "$METEOR_80K_INTERLEAVING" == "true" ]]; then
    $METEORDEMOD -m oqpsk -diff 1 -int 1 -s 80000 -sat METEOR-M-2-3 -t "$TLE_FILE" -f jpg -i "${RAMFS_AUDIO_BASE}.wav" >> $NOAA_LOG 2>&1
  else
    $METEORDEMOD -m oqpsk -diff 1 -s 72000 -sat METEOR-M-2-3 -t "$TLE_FILE" -f jpg -i "${RAMFS_AUDIO_BASE}.wav" >> $NOAA_LOG 2>&1
  fi
  
  rm *.gcp *.bmp "${RAMFS_AUDIO_BASE}.wav"

  for i in spread_*.jpg
  do
    $CONVERT -quality 100 $FLIP "$i" "$i" >> $NOAA_LOG 2>&1
  done

  for file in *.jpg; do
    new_filename=$(echo "$file" | sed -E 's/_[0-9]+-[0-9]+-[0-9]+-[0-9]+-[0-9]+-[0-9]+\.jpg$/.jpg/')        #This part removes unecessary numbers from the MeteorDemod image names using RegEx
    mv "$file" "$new_filename"

    ${IMAGE_PROC_DIR}/meteor_normalize_annotate.sh "$new_filename" "$new_filename" $METEOR_IMAGE_QUALITY >> $NOAA_LOG 2>&1
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "$new_filename" "${new_filename%.jpg}-thumb.jpg" >> $NOAA_LOG 2>&1
    mv "$new_filename" "${IMAGE_FILE_BASE}-${new_filename%.jpg}.jpg"
    mv "${new_filename%.jpg}-thumb.jpg" "${IMAGE_THUMB_BASE}-${new_filename%.jpg}.jpg"
    push_file_list="$push_file_list ${IMAGE_FILE_BASE}-${new_filename%.jpg}.jpg"
  done

  if [ "$DELETE_AUDIO" = true ]; then
    log "Deleting audio files" "INFO"
    rm "${RAMFS_AUDIO_BASE}.s"
  else
    if [ "$in_mem" == "true" ]; then
      log "Moving audio files out to the SD card" "INFO"
      mv "${RAMFS_AUDIO_BASE}.s" "${AUDIO_FILE_BASE}.s"
    fi
  fi
elif [ "$METEOR_RECEIVER" == "satdump" ]; then

  gain_option=""
  if [[ "$receiver" == "rtlsdr" ]]; then
    gain_option="--source_id $SDR_DEVICE_ID --gain"
  else
    gain_option="--general_gain"
  fi

  log "Starting SatDump live recording and decoding" "INFO"
  if [[ "$METEOR_80K_INTERLEAVING" == "true" ]]; then
    satdump live meteor_m2-x_lrpt_80k . --source $receiver --samplerate $samplerate --frequency "${METEOR_FREQ}e6" $gain_option $GAIN --timeout $CAPTURE_TIME --finish_processing >> $NOAA_LOG 2>&1
    rm satdump.logs meteor_m2-x_lrpt_80k.cadu dataset.json
  else
    satdump live meteor_m2-x_lrpt . --source $receiver --samplerate $samplerate --frequency "${METEOR_FREQ}e6" $gain_option $GAIN --timeout $CAPTURE_TIME --finish_processing >> $NOAA_LOG 2>&1
    rm satdump.logs meteor_m2-x_lrpt.cadu dataset.json
  fi
  
  log "Waiting for files to close" "INFO"
  sleep 2
  
  find MSU-MR/ -type f ! -name "*projected*" ! -name "*corrected*" -delete

  # Renaming files
  for i in MSU-MR/*.png; do
    # Use parameter expansion to remove the specified prefixes
    new_name="${i#msu_mr_rgb_}"
    new_name="${new_name#rgb_msu_mr_rgb_}"
    new_name="${new_name#rgb_msu_mr_rgb_}"
    new_name="${new_name#rgb_msu_mr_}"
    new_name="${new_name#msu_mr_}"

    # Rename the file with the new name
    mv "$i" "$new_name"
  done
  
  for i in MSU-MR/*_corrected.png
  do
    $CONVERT $FLIP "$i" "$i" >> $NOAA_LOG 2>&1
  done
  
  log "Annotating images and creating thumbnails" "INFO"
  for i in MSU-MR/*.png; do
    ${IMAGE_PROC_DIR}/meteor_normalize_annotate.sh "$i" "${i%.png}.jpg" $METEOR_IMAGE_QUALITY >> $NOAA_LOG 2>&1
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "$i" "${i%.png}-thumb.jpg" >> $NOAA_LOG 2>&1
    mv "${i%.png}.jpg" "${IMAGE_FILE_BASE}-${i%.png}.jpg"
    mv "${i%.png}-thumb.jpg" "${IMAGE_THUMB_BASE}-${i%.png}.jpg"
    rm $i
    push_file_list="$push_file_list ${IMAGE_FILE_BASE}-${i%.png}.jpg"
  done
  rm -r MSU-MR
else
  log "Receiver type '$METEOR_RECEIVER' not valid" "ERROR"
fi

#-------------------------------------------------------------------------------------------------------------------------------------------------------------------------

if [ -n "$(find /srv/images -maxdepth 1 -type f -name "$(basename "$IMAGE_FILE_BASE")*.jpg" -print -quit)" ]; then

  meteor_suffixes=(
      '-321-corrected.jpg'
      '-equidistant_321.jpg'
      '-mercator_321.jpg'
      '-spread_321.jpg'
      '-spread_123.jpg'
      '-221-corrected.jpg'
      '-equidistant_221.jpg'
      '-mercator_321.jpg'
      '-spread_221.jpg'
      '-equidistant_654.jpg'
      '-mercator_654.jpg'
      '-spread_654.jpg'
      '-Thermal_Channel_corrected.jpg'
      '-spread_rain.jpg'
      '-spread_IR.jpg'
  )

  # Iterate through the meteor_suffixes array
  for suffix in "${meteor_suffixes[@]}"; do
      if [[ -f "${IMAGE_THUMB_BASE}${suffix}" ]]; then
          cp "${IMAGE_THUMB_BASE}${suffix}" "${IMAGE_THUMB_BASE}-website-thumbnail.jpg"
          break
      fi
  done

  log "Some images were produced, let's push them to the database and social media" "INFO"
  if [[ "${PRODUCE_POLAR_AZ_EL}" == "true" ]]; then
    log "Producing polar graph of azimuth and elevation for pass" "INFO"
    polar_az_el=1
    epoch_end=$((EPOCH_START + CAPTURE_TIME))
    ${IMAGE_PROC_DIR}/polar_plot.py "${SAT_NAME}" \
                                    "${TLE_FILE}" \
                                    $EPOCH_START \
                                    $epoch_end \
                                    $LAT \
                                    $LON \
                                    $SAT_MIN_ELEV \
                                    $PASS_DIRECTION \
                                    "${IMAGE_FILE_BASE}-polar-azel.jpg" \
                                    "azel"
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "${IMAGE_FILE_BASE}-polar-azel.jpg" "${IMAGE_THUMB_BASE}-polar-azel.jpg"
  fi

  polar_direction=0
  if [[ "${PRODUCE_POLAR_DIRECTION}" == "true" ]]; then
    log "Producing polar graph of direction for pass" "INFO"
    polar_direction=1
    epoch_end=$((EPOCH_START + CAPTURE_TIME))
    ${IMAGE_PROC_DIR}/polar_plot.py "${SAT_NAME}" \
                                    "${TLE_FILE}" \
                                    $EPOCH_START \
                                    $epoch_end \
                                    $LAT \
                                    $LON \
                                    $SAT_MIN_ELEV \
                                    $PASS_DIRECTION \
                                    "${IMAGE_FILE_BASE}-polar-direction.png" \
                                    "direction"
    ${IMAGE_PROC_DIR}/thumbnail.sh 300 "${IMAGE_FILE_BASE}-polar-direction.png" "${IMAGE_THUMB_BASE}-polar-direction.png"
  fi

  # check if we got an image, and post-process if so

  log "I got a successful jpg images" "INFO"

  # insert or replace in case there was already an insert due to the spectrogram creation
  $SQLITE3 $DB_FILE "INSERT OR REPLACE INTO decoded_passes (pass_start, file_path, daylight_pass, sat_type, has_spectrogram, has_polar_az_el, has_polar_direction, gain) \
                                      VALUES ($EPOCH_START, \"$FILENAME_BASE\", $daylight, 0, $spectrogram, $polar_az_el, $polar_direction, $GAIN);"

  pass_id=$($SQLITE3 $DB_FILE "SELECT id FROM decoded_passes ORDER BY id DESC LIMIT 1;")
  $SQLITE3 $DB_FILE "UPDATE predict_passes \
                    SET is_active = 0 \
                    WHERE (predict_passes.pass_start) \
                    IN ( \
                      SELECT predict_passes.pass_start \
                      FROM predict_passes \
                      INNER JOIN decoded_passes \
                      ON predict_passes.pass_start = decoded_passes.pass_start \
                      WHERE decoded_passes.id = $pass_id \
                    );"

  # handle Slack pushing if enabled
  if [ "${ENABLE_SLACK_PUSH}" == "true" ]; then
    slack_push_annotation=""
    if [ "${GROUND_STATION_LOCATION}" != "" ]; then
      slack_push_annotation="Ground Station: ${GROUND_STATION_LOCATION}\n "
    fi
    slack_push_annotation="${slack_push_annotation}${SAT_NAME} ${capture_start}\n"
    slack_push_annotation="${slack_push_annotation} Max Elev: ${SAT_MAX_ELEVATION}° ${PASS_SIDE}\n"
    slack_push_annotation="${slack_push_annotation} Sun Elevation: ${SUN_ELEV}°\n"
    slack_push_annotation="${slack_push_annotation} Gain: ${gain} | ${PASS_DIRECTION}\n"

    pass_id=$($SQLITE3 $DB_FILE "SELECT id FROM decoded_passes ORDER BY id DESC LIMIT 1;")
    slack_push_annotation="${slack_push_annotation} <${SLACK_LINK_URL}?pass_id=${pass_id}>\n";

    ${PUSH_PROC_DIR}/push_slack.sh "${slack_push_annotation}" $push_file_list
  fi

  # handle twitter pushing if enabled
  if [ "${ENABLE_TWITTER_PUSH}" == "true" ]; then
    # create push annotation specific to twitter
    # note this is NOT the annotation on the image, which is driven by the config/annotation/annotation.html.j2 file
    twitter_push_annotation=""
    if [ "${GROUND_STATION_LOCATION}" != "" ]; then
      twitter_push_annotation="Ground Station: ${GROUND_STATION_LOCATION} "
    fi
    twitter_push_annotation="${twitter_push_annotation}${SAT_NAME} ${capture_start}"
    twitter_push_annotation="${twitter_push_annotation} Max Elev: ${SAT_MAX_ELEVATION}° ${PASS_SIDE}"
    twitter_push_annotation="${twitter_push_annotation} Sun Elevation: ${SUN_ELEV}°"
    twitter_push_annotation="${twitter_push_annotation} Gain: ${gain}"
    twitter_push_annotation="${twitter_push_annotation} | ${PASS_DIRECTION}"

    log "Pushing image enhancements to Twitter" "INFO"
    ${PUSH_PROC_DIR}/push_twitter.sh "${twitter_push_annotation}" $push_file_list
  fi

  # handle facebook pushing if enabled
  if [ "${ENABLE_FACEBOOK_PUSH}" == "true" ]; then
    facebook_push_annotation=""
    if [ "${GROUND_STATION_LOCATION}" != "" ]; then
      facebook_push_annotation="Ground Station: ${GROUND_STATION_LOCATION} "
    fi
    facebook_push_annotation="${facebook_push_annotation}${SAT_NAME} ${capture_start}"
    facebook_push_annotation="${facebook_push_annotation} Max Elev: ${SAT_MAX_ELEVATION}° ${PASS_SIDE}"
    facebook_push_annotation="${facebook_push_annotation} Sun Elevation: ${SUN_ELEV}°"
    facebook_push_annotation="${facebook_push_annotation} Gain: ${gain}"
    facebook_push_annotation="${facebook_push_annotation} | ${PASS_DIRECTION}"

    log "Pushing image enhancements to Facebook" "INFO"
    ${PUSH_PROC_DIR}/push_facebook.py "${facebook_push_annotation}" "${push_file_list}"
  fi

  # handle instagram pushing if enabled
  if [ "${ENABLE_INSTAGRAM_PUSH}" == "true" ]; then
    instagram_push_annotation=""
    if [ "${GROUND_STATION_LOCATION}" != "" ]; then
      instagram_push_annotation="Ground Station: ${GROUND_STATION_LOCATION} "
    fi
    instagram_push_annotation="${instagram_push_annotation}${SAT_NAME} ${capture_start}"
    instagram_push_annotation="${instagram_push_annotation} Max Elev: ${SAT_MAX_ELEVATION}° ${PASS_SIDE}"
    instagram_push_annotation="${instagram_push_annotation} Sun Elevation: ${SUN_ELEV}°"
    instagram_push_annotation="${instagram_push_annotation} Gain: ${gain}"
    instagram_push_annotation="${instagram_push_annotation} | ${PASS_DIRECTION}"

    convert "${IMAGE_FILE_BASE}-equidistant_321.jpg" -resize "1080x1350>" -gravity center -background black -extent 1080x1350 "${IMAGE_FILE_BASE}-instagram.jpg"

    log "Pushing image enhancements to Instagram" "INFO"
    ${PUSH_PROC_DIR}/push_instagram.py "${instagram_push_annotation}" $(sed 's|/srv/images/||' <<< "${IMAGE_FILE_BASE}-instagram.jpg") ${WEB_SERVER_NAME}
    rm "${IMAGE_FILE_BASE}-instagram.jpg"
    #if [[ "$daylight" -eq 1 ]]; then
    #  convert +append "${IMAGE_FILE_BASE}-MSA.jpg" "${IMAGE_FILE_BASE}-MSA-precip.jpg" "${IMAGE_FILE_BASE}-instagram.jpg"
    #else
    #  convert +append "${IMAGE_FILE_BASE}-MCIR.jpg" "${IMAGE_FILE_BASE}-MCIR-precip.jpg" "${IMAGE_FILE_BASE}-instagram.jpg"
  fi

  # handle matrix pushing if enabled
  if [ "${ENABLE_MATRIX_PUSH}" == "true" ]; then
    # create push annotation specific to matrix
    # note this is NOT the annotation on the image, which is driven by the config/annotation/annotation.html.j2 file
    matrix_push_annotation=""
    if [ "${GROUND_STATION_LOCATION}" != "" ]; then
        matrix_push_annotation="Ground Station: ${GROUND_STATION_LOCATION} "
    fi
    matrix_push_annotation="${matrix_push_annotation}${SAT_NAME} ${capture_start}"
    matrix_push_annotation="${matrix_push_annotation} Max Elev: ${SAT_MAX_ELEVATION}° ${PASS_SIDE}"
    matrix_push_annotation="${matrix_push_annotation} Sun Elevation: ${SUN_ELEV}°"
    matrix_push_annotation="${matrix_push_annotation} Gain: ${gain}"
    matrix_push_annotation="${matrix_push_annotation} | ${PASS_DIRECTION}"

    log "Pushing image enhancements to Matrix" "INFO"
    ${PUSH_PROC_DIR}/push_matrix.sh "${matrix_push_annotation}" $push_file_list
  fi

  if [ "$ENABLE_EMAIL_PUSH" == "true" ]; then
    log "Emailing images" "INFO"
    for i in $push_file_list
    do
      ${PUSH_PROC_DIR}/push_email.sh "${EMAIL_PUSH_ADDRESS}" "$i" "${push_annotation}" >> $NOAA_LOG 2>&1
      sleep 2
    done
  fi

  if [ "${ENABLE_DISCORD_PUSH}" == "true" ]; then
    log "Pushing images to Discord" "INFO"
    for i in $push_file_list
    do
      ${PUSH_PROC_DIR}/push_discord.sh "$i" "${push_annotation}" >> $NOAA_LOG 2>&1
      sleep 2
    done
  fi
else
  log "No images found, not pushing anything" "INFO"
fi

# calculate and report total time for capture
TIMER_END=$(date '+%s')
DIFF=$(($TIMER_END - $TIMER_START))
PROC_TIME=$(date -ud "@$DIFF" +'%H:%M.%S')
log "Total processing time: ${PROC_TIME}" "INFO"
