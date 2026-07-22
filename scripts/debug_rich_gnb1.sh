#!/bin/bash
bash -x /tmp/ran_collect/collect_rich_gnb1.sh > /tmp/ran_collect/debug_rich_gnb1.log 2>&1
echo "exit:$?" >> /tmp/ran_collect/debug_rich_gnb1.log
