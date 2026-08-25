#!/bin/bash
{
  echo '=== system state ==='
  systemctl is-system-running
  systemctl --failed --no-pager

  echo '=== root filesystem ==='
  findmnt -no SOURCE,FSTYPE,OPTIONS /

  echo '=== machine-id ==='
  ls -l /etc/machine-id /var/lib/dbus/machine-id 2>&1
  cat /etc/machine-id 2>&1

  echo '=== power monitor ==='
  systemctl status power_monitor.service --no-pager -l
  journalctl -b -u power_monitor.service --no-pager -o short-monotonic

  echo '=== interrupts ==='
  cat /proc/interrupts
  journalctl -k -b --no-pager -o short-monotonic |
    grep -Ei 'irq 34|nobody cared|rk805|pmic|regmap'

  echo '=== relevant GPIO ownership ==='
  gpioinfo gpiochip1 2>&1
  gpioinfo gpiochip2 2>&1

  echo '=== toolhead power ==='
  systemctl status opennept4une-toolhead-power.service --no-pager -l
  sudo /usr/local/sbin/opennept4une-toolhead-power status
  lsusb
  ls -l /dev/serial/by-id/ 2>&1
} 2>&1 | tee section4-followup.log
