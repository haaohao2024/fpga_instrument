#include "s9_gatt.h"
#include "s9_protocol.h"
#include <string.h>
#include <errno.h>
#include "FreeRTOS.h"
#include "task.h"
#include "bluetooth.h"
#include "conn.h"
#include "gatt.h"
#include "att.h"
#include "link_diag.h"
#include "bt_uuid.h"

#ifdef CONFIG_BT_BREDR
#define S9_GATT_ADV_FLAGS BT_LE_AD_GENERAL
#else
#define S9_GATT_ADV_FLAGS (BT_LE_AD_NO_BREDR|BT_LE_AD_GENERAL)
#endif

static const s9_gatt_hooks *callbacks;
static struct bt_conn *active_conn;
static uint32_t active_generation;
static uint8_t subscribed,registered;
static uint8_t info_read_snapshot[64];
static struct bt_uuid_128 uuid_service=BT_UUID_INIT_128(S9_UUID_SERVICE_BYTES);
static struct bt_uuid_128 uuid_info=BT_UUID_INIT_128(S9_UUID_INFO_BYTES);
static struct bt_uuid_128 uuid_rt=BT_UUID_INIT_128(S9_UUID_RT_BYTES);
static struct bt_uuid_128 uuid_cfg=BT_UUID_INIT_128(S9_UUID_CFG_BYTES);
static struct bt_uuid_128 uuid_file=BT_UUID_INIT_128(S9_UUID_FILE_BYTES);
static struct bt_uuid_128 uuid_status=BT_UUID_INIT_128(S9_UUID_STATUS_BYTES);

static ssize_t read_info(struct bt_conn *conn,const struct bt_gatt_attr *attr,void *buf,u16_t len,u16_t offset) {
    if(conn!=active_conn || !callbacks) return BT_GATT_ERR(BT_ATT_ERR_AUTHORIZATION);
    if(!offset) { callbacks->info_snapshot(info_read_snapshot);link_diag_event(LD_INFO,active_generation,info_read_snapshot[5],bt_conn_get_security(conn)); }
    return bt_gatt_attr_read(conn,attr,buf,len,offset,info_read_snapshot,sizeof(info_read_snapshot));
}
static ssize_t receive_fragment(struct bt_conn *conn,const struct bt_gatt_attr *attr,
                               const void *buf,u16_t len,u16_t offset,u8_t flags) {
    if(conn!=active_conn || !active_generation || !callbacks) return BT_GATT_ERR(BT_ATT_ERR_AUTHORIZATION);
    if(offset) return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    if(flags & BT_GATT_WRITE_FLAG_PREPARE) return BT_GATT_ERR(BT_ATT_ERR_NOT_SUPPORTED);
    if(len<9 || len>S9_BLE_FRAGMENT_MAX) return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    int r=callbacks->receive(active_generation,(uint8_t)(uintptr_t)attr->user_data,buf,len);
    link_diag_event(LD_RX,(uint32_t)(uintptr_t)attr->user_data,len,(uint32_t)r);
    if(r==S9_E_BUSY) return BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_RESOURCES);
    if(r) return BT_GATT_ERR(BT_ATT_ERR_INVALID_PDU);
    return len;
}
static void changed_ccc(const struct bt_gatt_attr *attr,u16_t value) {
    (void)attr;subscribed=(value==BT_GATT_CCC_NOTIFY);link_diag_event(LD_CCC,active_generation,value,active_conn?bt_conn_get_security(active_conn):0);
}
static struct bt_gatt_attr attributes[]={
    BT_GATT_PRIMARY_SERVICE(&uuid_service.uuid),
    BT_GATT_CHARACTERISTIC(&uuid_info.uuid,BT_GATT_CHRC_READ,BT_GATT_PERM_READ,read_info,NULL,NULL),
    BT_GATT_CHARACTERISTIC(&uuid_rt.uuid,BT_GATT_CHRC_WRITE|BT_GATT_CHRC_WRITE_WITHOUT_RESP,
        BT_GATT_PERM_WRITE_ENCRYPT,NULL,receive_fragment,(void *)(uintptr_t)S9_CH_RT),
    BT_GATT_CHARACTERISTIC(&uuid_cfg.uuid,BT_GATT_CHRC_WRITE,
        BT_GATT_PERM_WRITE_ENCRYPT,NULL,receive_fragment,(void *)(uintptr_t)S9_CH_CFG),
    BT_GATT_CHARACTERISTIC(&uuid_file.uuid,BT_GATT_CHRC_WRITE|BT_GATT_CHRC_WRITE_WITHOUT_RESP,
        BT_GATT_PERM_WRITE_ENCRYPT,NULL,receive_fragment,(void *)(uintptr_t)S9_CH_FILE),
    BT_GATT_CHARACTERISTIC(&uuid_status.uuid,BT_GATT_CHRC_NOTIFY,0,NULL,NULL,NULL),
    BT_GATT_CCC(changed_ccc,BT_GATT_PERM_READ|BT_GATT_PERM_WRITE_ENCRYPT)
};
static struct bt_gatt_service service=BT_GATT_SERVICE(attributes);
enum { STATUS_VALUE_INDEX=10 };

static void connected(struct bt_conn *conn,u8_t error) {
    link_diag_event(LD_CONNECT,error,0,0);
    if(error || !callbacks) return;
    struct bt_conn_info info;
    if(!conn || bt_conn_get_info(conn,&info) || info.type!=BT_CONN_TYPE_LE) return;
    if(active_conn) { (void)bt_conn_disconnect(conn,0x13);return; }
    uint32_t generation=callbacks->connected();link_diag_event(LD_GENERATION,generation,0,0);
    if(!generation) { (void)bt_conn_disconnect(conn,0x13);return; }
    taskENTER_CRITICAL();
    active_conn=bt_conn_ref(conn);active_generation=generation;subscribed=0;
    memset(info_read_snapshot,0,sizeof(info_read_snapshot));
    taskEXIT_CRITICAL();
    int sec=bt_conn_set_security(conn,BT_SECURITY_L2);
    link_diag_event(LD_SECURITY_REQUEST,(uint32_t)sec,bt_conn_get_security(conn),generation);
    if(sec) (void)bt_conn_disconnect(conn,0x13);
}
static void disconnected(struct bt_conn *conn,u8_t reason) {
    link_diag_event(LD_DISCONNECT,reason,active_generation,conn==active_conn);
    taskENTER_CRITICAL();
    struct bt_conn *old=active_conn==conn?active_conn:NULL;
    uint32_t generation=old?active_generation:0;
    if(old) { active_conn=NULL;active_generation=0;subscribed=0; }
    taskEXIT_CRITICAL();
    if(old) { callbacks->disconnected(generation);bt_conn_unref(old); }
    /* Advertising restarts from application task only after source cleanup. */
}
static void security_changed(struct bt_conn *conn,bt_security_t level,enum bt_security_err err){
    if(conn==active_conn)link_diag_event(LD_SECURITY_CHANGED,active_generation,level,err);
}
static struct bt_conn_cb connection_callbacks={.connected=connected,.disconnected=disconnected,.security_changed=security_changed};

int s9_gatt_init(const s9_gatt_hooks *hooks) {
    if(registered || !hooks || !hooks->connected || !hooks->disconnected || !hooks->receive || !hooks->info_snapshot) return -EINVAL;
    callbacks=hooks;
    int r=bt_gatt_service_register(&service);
    if(r) { callbacks=NULL;return r; }
    bt_set_bondable(false); /* No unqualified persistent bond/Flash region. */
    bt_conn_cb_register(&connection_callbacks);registered=1;return 0;
}
int s9_gatt_notify_fragment(uint32_t generation,const uint8_t *data,unsigned length) {
    if(!data || length<9 || length>S9_BLE_FRAGMENT_MAX) return -EINVAL;
    taskENTER_CRITICAL();
    struct bt_conn *conn=(subscribed && generation==active_generation && active_conn)?bt_conn_ref(active_conn):NULL;
    taskEXIT_CRITICAL();
    if(!conn) return -ENOTCONN;
    unsigned mtu=bt_gatt_get_mtu(conn);
    int r=length>mtu-3?-EMSGSIZE:bt_gatt_notify(conn,&attributes[STATUS_VALUE_INDEX],data,(u16_t)length);
    bt_conn_unref(conn);return r;
}
unsigned s9_gatt_mtu(void) {
    taskENTER_CRITICAL();struct bt_conn *conn=active_conn?bt_conn_ref(active_conn):NULL;taskEXIT_CRITICAL();
    unsigned mtu=conn?bt_gatt_get_mtu(conn):23;
    if(conn) bt_conn_unref(conn);
    return mtu>S9_BLE_MTU_MAX?S9_BLE_MTU_MAX:mtu;
}
int s9_gatt_connected(void) { return active_conn!=NULL; }
int s9_gatt_transport_ready(uint32_t generation){
    taskENTER_CRITICAL();
    int ready=active_conn && generation==active_generation && subscribed && bt_conn_get_security(active_conn)>=BT_SECURITY_L2;
    taskEXIT_CRITICAL();return ready;
}

void s9_gatt_disconnect(void){
    link_diag_event(LD_LOCAL_CLOSE,active_generation,0,0);
    taskENTER_CRITICAL();struct bt_conn *conn=active_conn?bt_conn_ref(active_conn):NULL;taskEXIT_CRITICAL();
    if(conn){(void)bt_conn_disconnect(conn,0x13);bt_conn_unref(conn);}
}
int s9_gatt_advertise(void) {
    if(!registered || active_conn) return -EBUSY;
    struct bt_le_adv_param p;memset(&p,0,sizeof(p));
    p.interval_min=BT_GAP_ADV_FAST_INT_MIN_2;p.interval_max=BT_GAP_ADV_FAST_INT_MAX_2;
    p.options=BT_LE_ADV_OPT_CONNECTABLE|BT_LE_ADV_OPT_USE_NAME|BT_LE_ADV_OPT_ONE_TIME;
    const struct bt_data ad[]={BT_DATA_BYTES(BT_DATA_FLAGS,S9_GATT_ADV_FLAGS),
        BT_DATA_BYTES(BT_DATA_UUID128_ALL,S9_UUID_SERVICE_BYTES)};
    return bt_le_adv_start(&p,ad,sizeof(ad)/sizeof(ad[0]),NULL,0);
}
