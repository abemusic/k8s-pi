#!/bin/bash

ansible k8s -m shell -a 'cat /sys/class/thermal/thermal_zone0/temp'