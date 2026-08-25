#!/bin/bash
{
  echo '=== system state ==='
  systemctl is-system-running
  systemctl --failed --no-pager

  echo '=== root filesystem ==='
  findmnt -no SOURCE,FSTYPE,OPTIONS /

  echo '=== machine-id ==='
  ls -l /etc/machine-id /var/lib/dbus/machine-id 2>&1
  if grep -Eq '^[0-9a-f]{32}$' /etc/machine-id 2>/dev/null; then
    echo 'machine-id: valid (value intentionally not logged)'
  else
    echo 'machine-id: MISSING OR INVALID'
  fi

  echo '=== power monitor ==='
  systemctl status power_monitor.service --no-pager -l
  journalctl -b -u power_monitor.service --no-pager -o short-monotonic

  echo '=== interrupts ==='
  cat /proc/interrupts
  journalctl -k -b --no-pager -o short-monotonic |
    grep -Ei 'irq 34|nobody cared|rk805|pmic|regmap'

  echo '=== relevant GPIO ownership ==='
  if gpioinfo --help 2>&1 | grep -q -- '-c, --chip'; then
    gpioinfo -c gpiochip1 2>&1
    gpioinfo -c gpiochip2 2>&1
  else
    gpioinfo gpiochip1 2>&1
    gpioinfo gpiochip2 2>&1
  fi

  echo '=== toolhead power ==='
  systemctl status opennept4une-toolhead-power.service --no-pager -l
  sudo /usr/local/sbin/opennept4une-toolhead-power status
  lsusb
  ls -l /dev/serial/by-id/ 2>&1
} 2>&1 | tee section4-followup.log
