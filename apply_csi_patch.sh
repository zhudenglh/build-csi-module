#!/bin/bash
set -e

MT76_DIR="$1"
if [ -z "$MT76_DIR" ]; then
    echo "Usage: $0 <mt76-source-dir>"
    exit 1
fi

cd "$MT76_DIR"
echo "Working in: $(pwd)"

# Download the CSI patch
wget -q -O /tmp/csi.patch \
  "https://raw.githubusercontent.com/cmonroe/feed-wifi-master/smartrg-master/mt76/patches/1001-wifi-mt76-mt7915-csi-implement-csi-support.patch"

# Try applying the patch (will partially succeed)
patch -p1 --fuzz=10 < /tmp/csi.patch 2>&1 || true

# === Fix mt76_connac_mcu.h ===
echo "Fixing mt76_connac_mcu.h..."
if ! grep -q "MCU_EXT_EVENT_CSI_REPORT" mt76_connac_mcu.h; then
    sed -i '/MCU_EXT_EVENT_MURU_CTRL = 0x9f,/a\\tMCU_EXT_EVENT_CSI_REPORT = 0xc2,' mt76_connac_mcu.h
fi
if ! grep -q "MCU_EXT_CMD_CSI_CTRL" mt76_connac_mcu.h; then
    sed -i '/MCU_EXT_CMD_WF_RF_PIN_CTRL = 0xbd,/a\\tMCU_EXT_CMD_CSI_CTRL = 0xc2,' mt76_connac_mcu.h
fi

# === Fix mt7915/Makefile ===
echo "Fixing Makefile..."
echo "Current Makefile:"
cat mt7915/Makefile

if ! grep -q "CONFIG_MTK_VENDOR" mt7915/Makefile; then
    # Try standard pattern first
    sed -i 's/EXTRA_CFLAGS += -DCONFIG_MT76_LEDS/EXTRA_CFLAGS += -DCONFIG_MT76_LEDS -DCONFIG_MTK_VENDOR/' mt7915/Makefile
    # If still not there, prepend it
    if ! grep -q "CONFIG_MTK_VENDOR" mt7915/Makefile; then
        sed -i '1i EXTRA_CFLAGS += -DCONFIG_MTK_VENDOR' mt7915/Makefile
    fi
fi
if ! grep -q "vendor.o" mt7915/Makefile; then
    # Try appending to the mt7915e-y line
    if grep -q "mt7915e-y" mt7915/Makefile; then
        sed -i '/mt7915e-y/s/$/ vendor.o/' mt7915/Makefile
    else
        echo "mt7915e-y += vendor.o" >> mt7915/Makefile
    fi
fi

echo "Fixed Makefile:"
cat mt7915/Makefile

# === Fix mt7915/mcu.c ===
echo "Fixing mcu.c..."
MCU_C="mt7915/mcu.c"

# Add forward declaration
if ! grep -q "mt7915_mcu_report_csi" "$MCU_C"; then
    # Find a good insertion point - after the last module_param line
    LINE=$(grep -n "MODULE_PARM_DESC" "$MCU_C" | tail -1 | cut -d: -f1)
    if [ -n "$LINE" ]; then
        sed -i "${LINE}a\\
\\
#ifdef CONFIG_MTK_VENDOR\\
static int mt7915_mcu_report_csi(struct mt7915_dev *dev, struct sk_buff *skb);\\
#endif" "$MCU_C"
    fi
fi

# Add case in event switch
if ! grep -q "MCU_EXT_EVENT_CSI_REPORT" "$MCU_C"; then
    # Find the line with mt7915_mcu_rx_log_message and add after the break
    LINE=$(grep -n "mt7915_mcu_rx_log_message" "$MCU_C" | head -1 | cut -d: -f1)
    if [ -n "$LINE" ]; then
        BREAK_LINE=$((LINE + 1))
        sed -i "${BREAK_LINE}a\\
#ifdef CONFIG_MTK_VENDOR\\
\tcase MCU_EXT_EVENT_CSI_REPORT:\\
\t\tmt7915_mcu_report_csi(dev, skb);\\
\t\tbreak;\\
#endif" "$MCU_C"
    fi
fi

# Append CSI functions at end of mcu.c (before final #endif if any, or at end)
if ! grep -q "mt7915_mcu_set_csi" "$MCU_C"; then
    cat >> "$MCU_C" << 'EOF'

#ifdef CONFIG_MTK_VENDOR
int mt7915_mcu_set_csi(struct mt7915_phy *phy, u8 mode,
			u8 cfg, u8 v1, u32 v2, u8 *mac_addr)
{
	struct mt7915_dev *dev = phy->dev;
	struct mt7915_mcu_csi req = {
		.band = phy != &dev->phy,
		.mode = mode,
		.cfg = cfg,
		.v1 = v1,
		.v2 = cpu_to_le32(v2),
	};

	if (mac_addr && is_valid_ether_addr(mac_addr))
		ether_addr_copy(req.mac_addr, mac_addr);

	return mt76_mcu_send_msg(&dev->mt76, MCU_EXT_CMD(CSI_CTRL), &req,
				 sizeof(req), false);
}

static int
mt7915_mcu_report_csi(struct mt7915_dev *dev, struct sk_buff *skb)
{
	struct mt76_connac2_mcu_rxd *rxd = (struct mt76_connac2_mcu_rxd *)skb->data;
	struct mt7915_phy *phy = &dev->phy;
	struct mt7915_mcu_csi_report *cr;
	struct csi_data *csi;
	int len, i;

	skb_pull(skb, sizeof(struct mt76_connac2_mcu_rxd));
	len = le16_to_cpu(rxd->len) - sizeof(struct mt76_connac2_mcu_rxd) + 24;
	if (len < sizeof(*cr))
		return -EINVAL;

	cr = (struct mt7915_mcu_csi_report *)skb->data;

	if (phy->csi.interval &&
	    le32_to_cpu(cr->ts) < phy->csi.last_record + phy->csi.interval)
		return 0;

	csi = kzalloc(sizeof(*csi), GFP_KERNEL);
	if (!csi)
		return -ENOMEM;

#define SET_CSI_DATA(_field) csi->_field = le32_to_cpu(cr->_field)
	SET_CSI_DATA(ch_bw);
	SET_CSI_DATA(rssi);
	SET_CSI_DATA(snr);
	SET_CSI_DATA(data_num);
	SET_CSI_DATA(data_bw);
	SET_CSI_DATA(pri_ch_idx);
	SET_CSI_DATA(info);
	SET_CSI_DATA(rx_mode);
	SET_CSI_DATA(h_idx);
	SET_CSI_DATA(ts);
	SET_CSI_DATA(band);
	if (csi->band && !phy->mt76->band_idx)
		phy = mt7915_ext_phy(dev);
#undef SET_CSI_DATA

	for (i = 0; i < csi->data_num; i++) {
		csi->data_i[i] = le16_to_cpu(cr->data_i[i]);
		csi->data_q[i] = le16_to_cpu(cr->data_q[i]);
	}

	memcpy(csi->ta, cr->ta, ETH_ALEN);
	csi->tx_idx = le32_get_bits(cr->trx_idx, GENMASK(31, 16));
	csi->rx_idx = le32_get_bits(cr->trx_idx, GENMASK(15, 0));

	INIT_LIST_HEAD(&csi->node);
	spin_lock_bh(&phy->csi.csi_lock);

	if (!phy->csi.enable) {
		kfree(csi);
		spin_unlock_bh(&phy->csi.csi_lock);
		return 0;
	}

	list_add_tail(&csi->node, &phy->csi.csi_list);
	phy->csi.count++;

	if (phy->csi.count > CSI_MAX_BUF_NUM) {
		struct csi_data *old;
		old = list_first_entry(&phy->csi.csi_list, struct csi_data, node);
		list_del(&old->node);
		kfree(old);
		phy->csi.count--;
	}

	if (csi->h_idx & BIT(15))
		phy->csi.last_record = csi->ts;
	spin_unlock_bh(&phy->csi.csi_lock);

	return 0;
}
#endif
EOF
fi

# === Fix mt7915/mcu.h ===
echo "Fixing mcu.h..."
if ! grep -q "mt7915_mcu_csi_report" mt7915/mcu.h; then
    cat >> mt7915/mcu.h << 'EOF'

#ifdef CONFIG_MTK_VENDOR
struct mt7915_mcu_csi {
	u8 band;
	u8 mode;
	u8 cfg;
	u8 v1;
	__le32 v2;
	u8 mac_addr[6];
	u8 _rsv[34];
} __packed;

struct csi_tlv {
	__le32 tag;
	__le32 len;
} __packed;

struct mt7915_mcu_csi_report {
	struct csi_tlv _t0;
	__le32 ver;
	struct csi_tlv _t1;
	__le32 ch_bw;
	struct csi_tlv _t2;
	__le32 rssi;
	struct csi_tlv _t3;
	__le32 snr;
	struct csi_tlv _t4;
	__le32 band;
	struct csi_tlv _t5;
	__le32 data_num;
	struct csi_tlv _t6;
	__le16 data_i[CSI_BW80_DATA_COUNT];
	struct csi_tlv _t7;
	__le16 data_q[CSI_BW80_DATA_COUNT];
	struct csi_tlv _t8;
	__le32 ts;
	struct csi_tlv _t9;
	__le32 data_bw;
	struct csi_tlv _t10;
	__le32 pri_ch_idx;
	struct csi_tlv _t11;
	u8 ta[8];
	struct csi_tlv _t12;
	__le32 info;
	struct csi_tlv _t13;
	__le32 rx_mode;
	struct csi_tlv _t14;
	__le32 h_idx;
	struct csi_tlv _t15;
	__le32 trx_idx;
	struct csi_tlv _t16;
	__le32 segment_num;
} __packed;
#endif
EOF
fi

# === Fix mt7915/mt7915.h ===
echo "Fixing mt7915.h..."
if ! grep -q "struct csi_data" mt7915/mt7915.h; then
    cat >> mt7915/mt7915.h << 'EOF'

#ifdef CONFIG_MTK_VENDOR
#define CSI_BW20_DATA_COUNT 64
#define CSI_BW40_DATA_COUNT 128
#define CSI_BW80_DATA_COUNT 256
#define CSI_MAX_BUF_NUM 3000

struct csi_data {
	u8 ch_bw;
	u16 data_num;
	s16 data_i[CSI_BW80_DATA_COUNT];
	s16 data_q[CSI_BW80_DATA_COUNT];
	u8 band;
	s8 rssi;
	u8 snr;
	u32 ts;
	u8 data_bw;
	u8 pri_ch_idx;
	u8 ta[ETH_ALEN];
	u32 info;
	u8 rx_mode;
	u32 h_idx;
	u16 tx_idx;
	u16 rx_idx;
	u32 segment_num;
	struct list_head node;
};

struct csi_info {
	struct list_head csi_list;
	spinlock_t csi_lock;
	u32 count;
	bool enable;
	u32 interval;
	u32 last_record;
};

int mt7915_mcu_set_csi(struct mt7915_phy *phy, u8 mode,
		       u8 cfg, u8 v1, u32 v2, u8 *mac_addr);
void mt7915_vendor_register(struct mt7915_phy *phy);
#endif
EOF
fi

# === Fix mt7915/init.c ===
echo "Fixing init.c..."
INIT_C="mt7915/init.c"
if ! grep -q "csi_list" "$INIT_C"; then
    # Add CSI init before mt76_register_device
    LINE=$(grep -n "ret = mt76_register_device" "$INIT_C" | head -1 | cut -d: -f1)
    if [ -n "$LINE" ]; then
        sed -i "${LINE}i\\
#ifdef CONFIG_MTK_VENDOR\\
\tINIT_LIST_HEAD(\&dev->phy.csi.csi_list);\\
\tspin_lock_init(\&dev->phy.csi.csi_lock);\\
\tmt7915_vendor_register(\&dev->phy);\\
#endif" "$INIT_C"
    fi
fi

# Need to add csi field to mt7915_phy struct
# Check if it exists
if ! grep -q "struct csi_info csi;" mt7915/mt7915.h; then
    # Find mt7915_phy struct and add csi field before closing brace
    # This is tricky - find the struct definition
    LINE=$(grep -n "^struct mt7915_phy {" mt7915/mt7915.h | head -1 | cut -d: -f1)
    if [ -n "$LINE" ]; then
        # Find the closing }; of this struct
        END=$(tail -n +$LINE mt7915/mt7915.h | grep -n "^};" | head -1 | cut -d: -f1)
        END=$((LINE + END - 1))
        sed -i "${END}i\\
#ifdef CONFIG_MTK_VENDOR\\
\tstruct csi_info csi;\\
#endif" "$INIT_C"
        # Actually need to add to mt7915.h not init.c
        sed -i "${END}i\\
#ifdef CONFIG_MTK_VENDOR\\
\tstruct csi_info csi;\\
#endif" mt7915/mt7915.h
    fi
fi

echo "=== Verification ==="
echo "CONFIG_MTK_VENDOR count:"
grep -rc "CONFIG_MTK_VENDOR" mt7915/ mt76_connac_mcu.h 2>/dev/null || true
echo "report_csi in mcu.c:"
grep -c "report_csi" mt7915/mcu.c || echo 0
echo "vendor.o in Makefile:"
grep "vendor.o" mt7915/Makefile || echo "MISSING"
echo "vendor.c exists:"
ls -la mt7915/vendor.c 2>/dev/null || echo "MISSING"
echo "Done!"
