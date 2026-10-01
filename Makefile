MOD := jellyfin_car_radio
ZIP := $(MOD).zip
MODS_DIR := $(HOME)/.local/share/BeamNG/BeamNG.drive/current/mods

.PHONY: build install clean

build: $(ZIP)

$(ZIP): $(shell find $(MOD) -type f)
	rm -f $(ZIP)
	cd $(MOD) && zip -r ../$(ZIP) .

install: build
	mkdir -p $(MODS_DIR)
	cp -f $(ZIP) $(MODS_DIR)/

clean:
	rm -f $(ZIP)
