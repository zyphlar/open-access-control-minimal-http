/*
 * Open Source RFID Access Controller - MINIMAL HTTP EDITION
 *
 * 11/27/2011 v0.01
 * Last build test with Arduino v00.22
 * 
 * Based on Open Source RFID Access Controller code by:
 * Arclight - arclight@23.org
 * Danozano - danozano@gmail.com
 * See: http://code.google.com/p/open-access-control/
 *
 * Minimal HTTP Edition by:
 * Will Bradley - bradley.will@gmail.com
 * See: https://github.com/zyphlar/open-access-control-minimal-http
 *
 * Notice: This is free software and is probably buggy. Use it at
 * at your own peril.  Use of this software may result in your
 * doors being left open, your stuff going missing, or buggery by
 * high seas pirates. No warranties are expressed on implied.
 * You are warned.
 *
 * 
 *
 * This program interfaces the Arduino to RFID, PIN pad and all
 * other input devices using the Wiegand-26 Communications
 * Protocol. It is recommended that the keypad inputs be
 * opto-isolated in case a malicious user shorts out the 
 * input device.
 * Outputs go to relays for door hardware/etc control.
 *
 * Relay outpus on digital pins 6,7,8,9
 * Reader 1: pins 2,3
 * Ethernet: pins 10,11,12,13 (reserved for the Ethernet shield)
 *
 * Quickstart tips: 
 * Compile and upload the code, then log in via serial console at 57600,8,N,1
 *
 */

#include <EEPROM.h>       // Needed for saving to non-voilatile memory on the Arduino.

#include <Ethernet.h>
#include <SPI.h>          
#include <Server.h>
#include <Client.h>

#include <WIEGAND26.h>    // Wiegand 26 reader format libary
#include <PCATTACH.h>     // Pcint.h implementation, allows for >2 software interupts.


/* Static user List - Implemented as an array for testing and access override 
 */                               

#define DEBUG 2                         // Set to 2 for display of raw tag numbers in log files, 1 for only denied, 0 for never.               

#define will   0xabcdef                  // Name and badge number in HEX. We are not using checksums or site ID, just the whole
#define jeremy   0xabcdef                  // output string from the reader.
#define jacob   0xabcdef
const long  superUserList[] = { will, jeremy, jacob};  // Super user table (cannot be changed by software)

#define PRIVPASSWORD 0x1234             // Console "priveleged mode" password

#define DOORDELAY 5000                  // How long to open door lock once access is granted. (2500 = 2.5s)
#define SENSORTHRESHOLD 100             // Analog sensor change that will trigger an alarm (0..255)

#define EEPROM_ALARM 0                  // EEPROM address to store alarm triggered state between reboots (0..511)
#define EEPROM_ALARMARMED 1             // EEPROM address to store alarm armed state between reboots
#define EEPROM_ALARMZONES 20            // Starting address to store "normal" analog values for alarm zone sensor reads.
#define KEYPADTIMEOUT 5000              // Timeout for pin pad entry. Users on keypads can enter commands after reader swipe.

#define EEPROM_FIRSTUSER 24
#define EEPROM_LASTUSER 1024
#define NUMUSERS  ((EEPROM_LASTUSER - EEPROM_FIRSTUSER)/5)  //Define number of internal users (200 for UNO/Duemillanova)


#define DOORPIN1 relayPins[0]           // Define the pin for electrified door 1 hardware
#define DOORPIN2 relayPins[2]           // Define the pin for electrified door 2 hardware
#define ALARMSTROBEPIN relayPins[3]     // Define the "non alarm: output pin. Can go to a strobe, small chime, etc
#define ALARMSIRENPIN  relayPins[1]     // Define the alarm siren pin. This should be a LOUD siren for alarm purposes.

byte reader1Pins[]={2,3};               // Reader 1 connected to pins 4,5
byte reader2Pins[]= {4,5};              // Reader2 connected to pins 6,7

//byte reader3Pins[]= {10,11};                // Reader3 connected to pins X,Y (Not implemented on v1.x and 2.x Access Control Board)

const byte analogsensorPins[] = {0,1,2,3};    // Alarm Sensors connected to other analog pins
const byte relayPins[]= {6,7,8,9};            // Relay output pins

bool door1Locked=true;                        // Keeps track of whether the doors are supposed to be locked right now
bool door2Locked=true;

unsigned long door1locktimer=0;               // Keep track of when door is supposed to be relocked
unsigned long door2locktimer=0;               // after access granted.

boolean doorChime=false;                       // Keep track of when door chime last activated
boolean doorClosed=false;                      // Keep track of when door last closed for exit delay

unsigned long alarmDelay=0;                    // Keep track of alarm delay. Used for "delayed activation" or level 2 alarm.
unsigned long alarmSirenTimer=0;               // Keep track of how long alarm has gone off


unsigned long consolefailTimer=0;               // Console password timer for failed logins
byte consoleFail=0;
#define numUsers (sizeof(superUserList)/sizeof(long))                  //User access array size (used in later loops/etc)
#define NUMDOORS (sizeof(doorPin)/sizeof(byte))
#define numAlarmPins (sizeof(analogsensorPins)/sizeof(byte))

//Other global variables
byte second, minute, hour, dayOfWeek, dayOfMonth, month, year;     // Global RTC clock variables. Can be set using DS1307.getDate function.

byte alarmActivated = EEPROM.read(EEPROM_ALARM);                   // Read the last alarm state as saved in eeprom.
byte alarmArmed = EEPROM.read(EEPROM_ALARMARMED);                  // Alarm level variable (0..5, 0==OFF) 

boolean sensor[4]={false};                                         // Keep track of tripped sensors, do not log again until reset.
unsigned long sensorDelay[2]={0};                                  // Same as above, but sets a timer for 2 of them. Useful for logging
                                                                   // motion detector hits for "occupancy check" functions.

// Enable up to 3 door access readers.
volatile long reader1 = 0;
volatile int  reader1Count = 0;
volatile long reader2 = 0;
volatile int  reader2Count = 0;
int userMask1=0;
int userMask2=0;
boolean keypadGranted=0;                                       // Variable that is set for authenticated users to use keypad after login

//volatile long reader3 = 0;                                   // Uncomment if using a third reader.
//volatile int  reader3Count = 0;

unsigned long keypadTime = 0;                                  // Timeout counter for  reader with key pad
unsigned long keypadValue=0;


// Serial terminal buffer (needs to be global)
char inString[40]={0};                                         // Size of command buffer (<=128 for Arduino)
byte inCount=0;
boolean privmodeEnabled = false;                               // Switch for enabling "priveleged" commands

// Enter a MAC address and IP address for your controller below.
// The IP address will be dependent on your local network:
byte mac[] = {  0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xED };
byte ip[] = { 10,1,1,2 };
byte server[] = { 10,1,1,1 }; // hsl-access

// Initialize the Ethernet client library
// with the IP address and port of the server 
// that you want to connect to (port 80 is default for HTTP):
Client client(server, 80);

/* Create an instance of the various C++ libraries we are using.
 */

DS1307 ds1307;        // RTC Instance
WIEGAND26 wiegand26;  // Wiegand26 (RFID reader serial protocol) library
PCATTACH pcattach;    // Software interrupt library

/* Set up some strings that will live in flash instead of memory. This saves our precious 2k of
 * RAM for something else.
*/

const prog_uchar rebootMessage[]          PROGMEM  = {"Access Control System rebooted."};

const prog_uchar doorChimeMessage[]       PROGMEM  = {"Front Door opened."};
const prog_uchar doorslockedMessage[]     PROGMEM  = {"All Doors relocked"};
const prog_uchar alarmtrainMessage[]      PROGMEM  = {"Alarm Training performed."};
const prog_uchar privsdeniedMessage[]     PROGMEM  = {"Access Denied. Priveleged mode is not enabled."};
const prog_uchar privsenabledMessage[]    PROGMEM  = {"Priveleged mode enabled."};
const prog_uchar privsdisabledMessage[]   PROGMEM  = {"Priveleged mode disabled."};
const prog_uchar privsAttemptsMessage[]   PROGMEM  = {"Too many failed attempts. Try again later."};

const prog_uchar consolehelpMessage1[]    PROGMEM  = {"Valid commands are:"};
const prog_uchar consolehelpMessage2[]    PROGMEM  = {"(d)ate, (s)show user, (m)odify user <num>  <usermask> <tagnumber>"};
const prog_uchar consolehelpMessage3[]    PROGMEM  = {"(a)ll user dump,(r)emove_user <num>,(o)open door <num>"};
const prog_uchar consolehelpMessage4[]    PROGMEM  = {"(u)nlock all doors,(l)lock all doors"};
const prog_uchar consolehelpMessage5[]    PROGMEM  = {"(1)disarm_alarm, (2)arm_alarm,(3)train_alarm (9)show_status"};
const prog_uchar consolehelpMessage6[]    PROGMEM  = {"(e)nable <password> - enable or disable priveleged mode"};                                       
const prog_uchar consoledefaultMessage[]  PROGMEM  = {"Invalid command. Press '?' for help."};

const prog_uchar statusMessage1[]         PROGMEM  = {"Alarm armed state (1=armed):"};
const prog_uchar statusMessage2[]         PROGMEM  = {"Alarm siren state (1=activated):"};
const prog_uchar statusMessage3[]         PROGMEM  = {"Front door open state (0=closed):"};
const prog_uchar statusMessage4[]         PROGMEM  = {"Roll up door open state (0=closed):"};     
const prog_uchar statusMessage5[]         PROGMEM  = {"Door 1 unlocked state(1=locked):"};                   
const prog_uchar statusMessage6[]         PROGMEM  = {"Door 2 unlocked state(1=locked):"}; 


// strings for storing results from web server
String httpresponse = "";
String username = "";
bool authorized = false;
bool relay1engaged = false;

void setup(){           // Runs once at Arduino boot-up


    Wire.begin();   // start Wire library as I2C-Bus Master

  /* Attach pin change interrupt service routines from the Wiegand RFID readers
   */
  pcattach.PCattachInterrupt(reader1Pins[0], callReader1Zero, CHANGE); 
  pcattach.PCattachInterrupt(reader1Pins[1], callReader1One,  CHANGE);  
  pcattach.PCattachInterrupt(reader2Pins[1], callReader2One,  CHANGE);
  pcattach.PCattachInterrupt(reader2Pins[0], callReader2Zero, CHANGE);

  //Clear and initialize readers
  wiegand26.initReaderOne(); //Set up Reader 1 and clear buffers.
  wiegand26.initReaderTwo(); 


  //Initialize output relays

  for(byte i=0; i<4; i++){        
    pinMode(relayPins[i], OUTPUT);                                                      
    digitalWrite(relayPins[i], LOW);                  // Sets the relay outputs to LOW (relays off)
  }


  ds1307.setDateDs1307(0,49,1,3,7,6,11);         
  /*  Sets the date/time (needed once at commissioning)
   
   byte second,        // 0-59
   byte minute,        // 0-59
   byte hour,          // 1-23
   byte dayOfWeek,     // 1-7
   byte dayOfMonth,    // 1-28/29/30/31
   byte month,         // 1-12
   byte year);          // 0-99
   */



  Serial.begin(57600);	               	       // Set up Serial output at 8,N,1,57600bps

  
  
  // start the Ethernet connection:
  Ethernet.begin(mac, ip);
  // start the serial library:
  //Serial.begin(9600);
  // give the Ethernet shield a second to initialize:
  //delay(1000);
  
  


//  hardwareTest(100);                         // IO Pin testing routing (use to check your inputs with hi/lo +(5-12V) sources)
                                               // Also checks relays


}
void loop()                                     // Main branch, runs over and over again
{ 
  //////////////////////////  
  // Reader input/authentication section  
  //////////////////////////
  if(reader1Count >= 26)
  {                           //  When tag presented to reader1 (No keypad on this reader)

  
     Serial.println("connecting...");
  
     // if you get a connection, report back via serial:
     if (client.connect())
     {
        Serial.println("connected");
        
        Serial.print("GET /~access/access?device=laser&id=");   
        Serial.print(reader1, HEX);
        Serial.println(" HTTP/1.0");
        Serial.println();
        
        client.print("GET /~access/access?device=laser&id=");   
        client.print(reader1, HEX);
        client.println(" HTTP/1.0");
        client.println();

        // reset values coming from http
        httpresponse = "";
        username = "";
        authorized = false;
     }
     else 
     {
        // kf you didn't get a connection to the server:
        Serial.println("connection failed");
     }
     
     wiegand26.initReaderOne();                     // Reset for next tag scan  
     
  }

  
  while (client.available()) {
    char thisChar = client.read();
    // only fill up httpresponse with data after a ^ sign.
    if (httpresponse.charAt(0) == '^' || thisChar == '^') {
      httpresponse += thisChar;
    }
  }
  
  if(!client.available() && httpresponse.length()>0) { 
    Serial.println("Response: ");
    
    Serial.println(httpresponse);
    int c = httpresponse.indexOf('^');
    int d = httpresponse.indexOf('|');
    int e = httpresponse.indexOf('$');
    
    Serial.print("IndexOf:");
    Serial.println(c);
    Serial.println(d);
    
    Serial.println("SubStr:");
    Serial.println(httpresponse.substring(c+1,d));

    username = httpresponse.substring(c+1,d);
    
    Serial.print("User: ");
    Serial.println(username);
    
    Serial.println("SubStr:");
    Serial.println(httpresponse.substring(d+1,e));
    
    if(httpresponse.substring(d+1,e) == "OK") {
      authorized = true; 
    }
    
    Serial.print("Auth: ");
    Serial.println(authorized);
    
    
    Serial.println("End Response");
    httpresponse = "";
  }
  
  // if the server's disconnected, stop the client:
  if (!client.connected()) {
    client.stop();
  }
  
  //////////////////////////
  // Normal operation section
  //////////////////////////  
  
  if(authorized) {
    
  }
  
} // End of loop()




/* Access System Functions - Modify these as needed for your application. 
 These function control lock/unlock and user lookup.
 */

int checkSuperuser(long input){       // Check to see if user is in the user list. If yes, return their index value.
int found=-1;
  for(int i=0; i<=numUsers; i++){   
    if(input == superUserList[i]){

      Serial.print("Superuser ");
      Serial.print(i,DEC);
      Serial.println(" found.");
      found=i;
      return found;    
    }
  }                   
 
  return found;             //If no, return -1
}


void doorUnlock(int input) {          //Send an unlock signal to the door and flash the Door LED
byte dp=1;
  if(input == 1) {
    dp=DOORPIN1; }
   else(dp=DOORPIN2);
  
  digitalWrite(dp, HIGH);
  Serial.print("Door ");
  Serial.print(input,DEC);
  Serial.println(" unlocked");

}

void doorLock(int input) {          //Send an unlock signal to the door and flash the Door LED
byte dp=1;
  if(input == 1) {
    dp=DOORPIN1; }
   else(dp=DOORPIN2);

  digitalWrite(dp, LOW);
  Serial.print("Door ");
  Serial.print(input,DEC);
  Serial.println(" locked");

}


/* Wrapper functions for interrupt attachment
 Could be cleaned up in library?
 */
void callReader1Zero(){wiegand26.reader1Zero();}
void callReader1One(){wiegand26.reader1One();}
void callReader2Zero(){wiegand26.reader2Zero();}
void callReader2One(){wiegand26.reader2One();}
void callReader3Zero(){wiegand26.reader3Zero();}
void callReader3One(){wiegand26.reader3One();}


