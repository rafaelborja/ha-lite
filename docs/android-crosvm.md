# Notes: Home Assistant OS in a crosvm VM on a rooted Android phone

Lessons from running HAOS on a phone with pKVM/crosvm. Not part of the add-on.

- **Fixed VM size, never the balloon.** `-m size=2048 --no-balloon`. A boot with `--init-mem` +
  `--balloon-page-reporting` corrupted guest memory within minutes (database and `.storage` files written with
  garbage, ext4 bitmap errors). With HA Lite, 2 GB leaves ~1 GB available inside the VM.
- **One vCPU** was the only reliable value on that SoC (more cores hung at "Bringing up secondary CPUs").
- **USB passthrough survives a hub reset only if something re-attaches.** Keep a small loop on the Android side that
  re-attaches devices by VID:PID (`crosvm usb attach`) whenever they re-enumerate. Inside the VM, the HA Lite healer
  restarts the add-on the Supervisor's watchdog gave up on.
- **Battery watch.** If the phone stops charging (a hub that stops delivering power), the VM dies with the battery.
  Publish the battery level to MQTT, warn below 40 %, shut the guest down cleanly (`hassio.host_shutdown`) at 15 %,
  press the virtual power button from the Android side at 8 % as a fallback, and restart the VM once charging again.
- **Never reboot the phone while crosvm runs**; shut the guest down from inside first.
- **Turn off automatic OS updates** on a rooted phone: an OTA removes root and the VM no longer starts.
