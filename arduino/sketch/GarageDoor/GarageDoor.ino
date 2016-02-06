//
// GarageDoor - based on RBL SimpleControls app
//

// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files (the "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
// - The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

//"services.h/spi.h/boards.h" is needed in every new project
#include <SPI.h>
#include <boards.h>

//#define USE_BLE_MINI

#ifdef USE_BLE_MINI
#include <ble_mini.h>

#define ble_available BLEMini_available
#define ble_read BLEMini_read
#define ble_write BLEMini_write
#define ble_connected() false

#else
#include <ble_shield.h>
#endif

#include <MD5.h>
#include <TimerOne.h>
#include "shared_key.h"
#include "shared_protocol.h"

#ifndef USE_BLE_MINI
// project-specific BLE service definition
#include <services.h>
#include <lib_aci.h>
static hal_aci_data_t g_setup_msgs[NB_SETUP_MESSAGES] PROGMEM = SETUP_MESSAGES_CONTENT;
static services_pipe_type_mapping_t g_services_pipe_type_mapping[NUMBER_OF_PIPES] = SERVICES_PIPE_TYPE_MAPPING_CONTENT;
#endif

union long_hex {
    uint32_t lunsign;
    struct {
        uint8_t b0;
        uint8_t b1;
        uint8_t b2;
        uint8_t b3;
    } lbytes;
};

typedef enum {
  app_state_normal,
  app_state_autoshut_pending,
  app_state_autoshut_active,
  app_state_autoshut_done
} app_state_enum;

// application
#ifdef USE_BLE_MINI
#define kAutoCloseDisabledDIPin       6
#else
#define kAutoCloseDisabledDIPin       1
#endif
#define kGarageOpenStatusDIPin        2
#define kGarageClosedStatusDIPin      3
#define kGarageControlDOPin           4
#define kAlarmControlDOPin            5

#define kAutoShutTimeout              (60*5)    // seconds
#define kAutoShutWarningBeepCount     10
#define kSignatureLength              16

// globals
static union long_hex key_part;
static app_state_enum app_state = app_state_normal;
static int autoshut_dooropencount = 0;
static int autoshut_countdown;

// fwd declare
void timerCallback();

uint8_t *get_signature_for_bytes(uint8_t *bytes, uint16_t length, uint32_t key1, uint32_t key2)
{
    // length must be <= 4
    if (length > 4) {
      return 0;
    }
    
    byte data[12];    // length = 4 bytes + key1 + key2
    memcpy(data, bytes, length);
    
    union long_hex lu;
    byte *dest = &data[length];

    lu.lunsign = key1;
    *dest++ = lu.lbytes.b3;
    *dest++ = lu.lbytes.b2;
    *dest++ = lu.lbytes.b1;
    *dest++ = lu.lbytes.b0;

    lu.lunsign = key2;
    *dest++ = lu.lbytes.b3;
    *dest++ = lu.lbytes.b2;
    *dest++ = lu.lbytes.b1;
    *dest++ = lu.lbytes.b0;
    
    return make_hash((unsigned char*)data, length + 8);
}

void setup()
{
  int seed = analogRead(0);
  randomSeed(seed);
  key_part.lunsign = 0;
  
#ifndef USE_BLE_MINI
  // Enable serial debug
  Serial.begin(57600);
  Serial.print("\n*** GarageDoor starting - random seed:");
  Serial.print(seed);
  Serial.print("\n");    
#endif
    
#ifdef USE_BLE_MINI
  BLEMini_begin(57600);
#else
  // Default pins set to 9 and 8 for REQN and RDYN
  // Set your REQN and RDYN here before ble_begin() if you need
  //ble_set_pins(3, 2);
  
  // Init. and start BLE library.
  ble_begin(g_setup_msgs, NB_SETUP_MESSAGES,
     g_services_pipe_type_mapping, NUMBER_OF_PIPES,
     PIPE_UART_OVER_BTLE_UART_TX_TX, PIPE_UART_OVER_BTLE_UART_RX_RX,
     PIPE_DEVICE_INFORMATION_HARDWARE_REVISION_STRING_SET);
#endif

  pinMode(kAutoCloseDisabledDIPin, INPUT_PULLUP);
  pinMode(kGarageOpenStatusDIPin, INPUT_PULLUP);
  pinMode(kGarageClosedStatusDIPin, INPUT_PULLUP);  

  pinMode(kGarageControlDOPin, OUTPUT);
  pinMode(kAlarmControlDOPin, OUTPUT);
  
  Timer1.initialize(500000);             // initialize timer1, and set a 1/2 second period
  Timer1.attachInterrupt(timerCallback); // attaches callback() as a timer interrupt
}

void timerCallback()
{
  // NO rear input == closed (0) and NC front input == open (0) 
  bool door_fully_open = (digitalRead(kGarageOpenStatusDIPin) == 0) && (digitalRead(kGarageClosedStatusDIPin) == 0);
  
  switch (app_state) {
    case app_state_normal:
      if (door_fully_open) {
        if (++autoshut_dooropencount > kAutoShutTimeout) {
          autoshut_dooropencount = 0;  // reset for next time
          autoshut_countdown = kAutoShutWarningBeepCount*2;
          app_state = app_state_autoshut_pending;
        }
      } else {
        autoshut_dooropencount = 0;
      }
      break;
      
    case app_state_autoshut_pending:
      if (!door_fully_open) {
        // abort
        digitalWrite(kAlarmControlDOPin, LOW);
        app_state = app_state_normal;
      } else {      
        --autoshut_countdown;
        digitalWrite(kAlarmControlDOPin, (autoshut_countdown % 2) ? HIGH : LOW);
  
        if (autoshut_countdown == 0) {        
          // shut garage door: pulse HIGH for 2 seconds
          digitalWrite(kGarageControlDOPin, HIGH);
          autoshut_countdown = 4;
          app_state = app_state_autoshut_active;
        }
      }
      break;
      
    case app_state_autoshut_active:
      if (--autoshut_countdown == 0) {
        digitalWrite(kGarageControlDOPin, LOW);      
        if (!door_fully_open) {
          // door (started to) shut properly - reset back to normal state
          app_state = app_state_normal;        
        } else {
          // door did not start to shut - nothing else to do
          app_state = app_state_autoshut_done;
          Timer1.stop();
        }
      }
      break;
      
    case app_state_autoshut_done:
      break;    
  }
}

void loop()
{
  static byte old_state = LOW;
  
  // If data is ready
  while(ble_available())
  {
    byte payload[4];
    byte rx_signature[kSignatureLength];
    
    // read out signature, command and data
    for (int i=0; i<kSignatureLength; i++) {
      rx_signature[i] = ble_read();      
    }

    byte command = payload[0] = ble_read();
    byte sequence = payload[1] = ble_read();
    byte data1 = payload[2] = ble_read();
    byte data2 = payload[3] = ble_read();

#ifndef USE_BLE_MINI
    Serial.print("Receiving <--- cmd: ");    
    Serial.print(command, HEX);
    Serial.print(" seq: ");    
    Serial.print(sequence, HEX);
    Serial.print(" data: ");    
    Serial.print(data1, HEX);
    Serial.print(" ");    
    Serial.print(data2, HEX);
    Serial.print("\n");
#endif
    
    uint8_t *calc_signature = get_signature_for_bytes(payload, 4, kSharedKey, key_part.lunsign);    
    bool signature_matched = (strncmp((const char *)calc_signature, (const char *)rx_signature, kSignatureLength) == 0);

#ifndef USE_BLE_MINI
    Serial.print("signature (");
    for (int i=0; i<kSignatureLength; i++) {
      Serial.print(rx_signature[i], HEX);
    }
    Serial.print(signature_matched ? ") ok\n" : ") invalid\n");
#endif

    switch (command) {
      case kCmdGetKeyPart:
        key_part.lunsign = random(0x7FFFFFFF);

#ifndef USE_BLE_MINI
        Serial.print("kCmdGetKeyPart: ");
        Serial.print(key_part.lunsign, HEX);
        Serial.print("\n");    
#endif

        ble_write(kResponseSignature);
        ble_write(sequence);
        ble_write(kResponseOK);           
        ble_write(4);  // data length
        ble_write(key_part.lbytes.b3);
        ble_write(key_part.lbytes.b2);
        ble_write(key_part.lbytes.b1);
        ble_write(key_part.lbytes.b0);         
        break;

      case kCmdGetStatus: {
        int diClosed = digitalRead(kGarageClosedStatusDIPin);
        int diOpen = digitalRead(kGarageOpenStatusDIPin);

#ifndef USE_BLE_MINI
        Serial.print("kCmdGetStatus: ");
        Serial.print(diClosed);
        Serial.print(diOpen);
        Serial.print("\n");    
#endif

        ble_write(kResponseSignature);
        ble_write(sequence);
        ble_write(kResponseOK);           
        ble_write(2);  // data length
        ble_write(diClosed);         
        ble_write(diOpen);         
        break;
      }
        
      case kCmdControl: {       
        bool success = false;
        
        if (data1 == 0x01) {
           success = signature_matched;
           if (success) {
#ifndef USE_BLE_MINI
             Serial.print("kCmdControl(on) accepted\n");
#endif
             digitalWrite(kGarageControlDOPin, HIGH);
           } else {
#ifndef USE_BLE_MINI
             Serial.print("kCmdControl(on) signature mismatch");    
             Serial.print("\n");    
#endif             
           }

           // reset key for next time           
           key_part.lunsign = 0;           
        } else {
          success = true;
#ifndef USE_BLE_MINI
          Serial.print("kCmdControl(off) accepted\n");
#endif
          digitalWrite(kGarageControlDOPin, LOW);
        }    
        
        ble_write(kResponseSignature);
        ble_write(sequence);
        ble_write(success ? kResponseOK : kResponseErrorSig);           
        ble_write(0);  // data length
        break;    
      }
        
      default:
#ifndef USE_BLE_MINI
        Serial.print("Invalid command: ");
        Serial.print(command);
        Serial.print("\n");
#endif        

        ble_write(kResponseSignature);
        ble_write(sequence);
        ble_write(kResponseErrorInvalidCommand);           
        ble_write(0);  // data length
        break;      
    }
  }
  
  if ((ble_connected() && (app_state < app_state_autoshut_active)) || (digitalRead(kAutoCloseDisabledDIPin) == 0)) {
    // active BLE connection or auto-close disabled switch closed resets the auto-shut sequence
    autoshut_dooropencount = 0;
    digitalWrite(kAlarmControlDOPin, LOW);
    app_state = app_state_normal;
  }
  
#ifndef USE_BLE_MINI
  // Allow BLE Shield to send/receive data
  ble_do_events();  
#endif  
}



