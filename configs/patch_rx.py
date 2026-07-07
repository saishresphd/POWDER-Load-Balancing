#!/usr/bin/env python3
filepath = "/tmp/srsran4g/lib/src/phy/rf/rf_zmq_imp_rx.c"
with open(filepath, "r") as f:
    content = f.read()

old = '    // Receive baseband\n    for (n = (n < 0) ? 0 : -1; n < 0 && rf_zmq_rx_is_running(q);) {\n      n = zmq_recv(q->sock, q->temp_buffer, ZMQ_MAX_BUFFER_SIZE, 0);\n      if (n == -1) {\n        if (rf_zmq_handle_error(q->id, "asynchronous rx baseband receive")) {\n          return NULL;\n        }\n\n      } else if (n > ZMQ_MAX_BUFFER_SIZE) {'

new = '    // Receive baseband\n    // NOTE: For REQ sockets, on recv failure break inner loop so outer loop re-sends\n    for (n = (n < 0) ? 0 : -1; n < 0 && rf_zmq_rx_is_running(q);) {\n      n = zmq_recv(q->sock, q->temp_buffer, ZMQ_MAX_BUFFER_SIZE, 0);\n      if (n == -1) {\n        if (rf_zmq_handle_error(q->id, "asynchronous rx baseband receive")) {\n          return NULL;\n        }\n        if (q->socket_type == ZMQ_REQ) {\n          break;\n        }\n\n      } else if (n > ZMQ_MAX_BUFFER_SIZE) {'

if old in content:
    content = content.replace(old, new)
    with open(filepath, "w") as f:
        f.write(content)
    print("PATCH APPLIED OK")
else:
    print("ERROR: pattern not found — showing lines 54-65:")
    lines = content.split("\n")
    for i, line in enumerate(lines[53:66], 54):
        print(f"{i}: {repr(line)}")
