# Notification Mirror Hardware Validation Matrix

The state machine (`G1NotificationMirror`) and the gesture precedence
(`G1LensSurfaceArbiter`) are covered by unit tests. Everything below needs real
dual-arm glasses, because it depends on firmware behavior documented in
`GLASSES_FIRMWARE_BEHAVIOR.md`.

Enable **Heads-Up > Notifications > Mirror notifications to the lens** first.

## Scenarios

1. Arrival shows the envelope
- Tap "Simulate incoming notification" with glasses connected.
- Verify the envelope bitmap appears and the message text does **not**.
- Simulate twice more and verify the unread count appears beside the envelope.

2. Tilt to read
- With one unread notification, tilt your head up.
- Verify the message replaces the envelope, and that it is the **newest** queued
  message rather than the oldest.
- Verify the notification is treated as acknowledged at reveal time: the unread
  count drops immediately, not when the message is dismissed.

3. Firmware auto head-down is absorbed
- Tilt up and hold for several seconds.
- Verify the message stays visible through the firmware's own `headDown`, which
  arrives roughly 500-700 ms after every `headUp`.
- Verify both arms reporting the same gesture (~200 ms apart) reveals one message
  rather than burning through two.

4. Dismissal
- Look back down after the hold window and verify the lens clears, or shows the
  envelope again when other messages are still queued.
- Tilt up and then wait without looking down; verify the read timeout clears it.

5. Navigation takes over
- Queue a notification, then start navigation.
- Verify the route map owns the lens and no envelope or message appears.
- Verify head gestures drive the map, not the mirror.
- End navigation and verify the queued notification's envelope returns.

6. Transit non-interference
- Queue a notification, then open the transit widget.
- Verify a head-down does not clear the mirror content via transit's own handler.
- Verify transit still responds to head gestures once the mirror is empty.

7. Stock dashboard suppression
- With an envelope or message showing, tilt repeatedly.
- Verify the stock dashboard never covers the mirror content.

8. Connection loss
- Disconnect the glasses while an envelope or message is showing.
- Verify no crash, the queue resets, and the UI reports the disconnect.
- Reconnect and verify a freshly simulated notification still works.

9. Real local notification
- Allow notifications, then use "Schedule a real notification in 2s" and keep the
  app in the foreground.
- Verify the envelope appears when the notification is delivered.
- Repeat while backgrounding the app before delivery, and verify the envelope
  appears only after returning to the app or opening the notification. There is no
  `bluetooth-central` background mode, so suspended delivery cannot reach the lens.

10. Firmware safety
- Capture the UART log for a whole session.
- Verify no `0x0A`/`0x0B` head-up mode command is sent by this feature, and that no
  Even AI recording prompt appears.
