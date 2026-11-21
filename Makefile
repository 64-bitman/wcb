FLAGS ?=

SRC_DIR := src
BUILD_DIR := build
CORE_DIR := $(SRC_DIR)/core
SCANNER_DIR := $(SRC_DIR)/scanner
PROTOCOL_DIR := $(SRC_DIR)/protocol

CORE_SRC := types.c3 table.c3 connection.c3
SCANNER_SRC := main.c3 parser.c3 validate.c3 codegen.c3

WAYLAND_XML := $(PROTOCOL_DIR)/wayland.xml

SCANNER_TARGET := $(BUILD_DIR)/wcb_scanner
SOURCE_TARGET := $(BUILD_DIR)/wcb.c3l

CLIENT_PROTOCOL := $(BUILD_DIR)/client.c3
SERVER_PROTOCOL := $(BUILD_DIR)/server.c3


all: $(SOURCE_TARGET)

dirs:
	mkdir -p $(BUILD_DIR)

$(SOURCE_TARGET): dirs protocol
	c3c source-lib -o wcb -C \
		$(addprefix $(CORE_DIR)/, $(CORE_SRC)) \
		$(CLIENT_PROTOCOL) $(SERVER_PROTOCOL)

$(SCANNER_TARGET): $(addprefix $(SCANNER_DIR)/, $(SCANNER_SRC))
	c3c compile -o $@ $(FLAGS) $^

protocol: $(SCANNER_TARGET)
	$(SCANNER_TARGET) "wcb::protocol" client $(WAYLAND_XML) $(CLIENT_PROTOCOL)
	$(SCANNER_TARGET) "wcb::protocol" server $(WAYLAND_XML) $(SERVER_PROTOCOL)

test: protocol
	c3c compile-test $(FLAGS) \
		$(addprefix $(CORE_DIR)/, $(CORE_SRC)) \
		$(CLIENT_PROTOCOL) $(SERVER_PROTOCOL)

clean:
	rm -r build/*

.PHONY: dirs protocol test clean
