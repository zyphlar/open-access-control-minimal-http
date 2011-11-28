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
 * Relay outputs on digital pins 6,7,8,9 //TODO: fix this conflict -WB
 * Reader 1: pins 2,3
 * Ethernet: pins 10,11,12,13 (reserved for the Ethernet shield)
 * LCD: pins 7, 6, 5, 4, 3, 2
 *
 * Quickstart tips: 
 * Compile and upload the code, then log in via serial console at 57600,8,N,1
 *
 */

/////////////////
// Includes
/////////////////

#include <EEPROM.h>       // Needed for saving to non-voilatile memory on the Arduino.

#include <Ethernet.h>
#include <SPI.h>          
#include <Server.h>
#include <Client.h>

#include <WIEGAND26.h>    // Wiegand 26 reader format libary
#include <PCATTACH.h>     // Pcint.h implementation, allows for >2 software interupts.

#include <LiquidCrystal.h>

// Create an instance of the various C++ libraries we are using.
WIEGAND26 wiegand26;  // Wiegand26 (RFID reader serial protocol) library
PCATTACH pcattach;    // Software interrupt library

/////////////////
// Global variables
/////////////////

// pin assignments
byte reader1Pins[]={2,3};               // Reader 1 pins
const byte relayPins[]= {6,7,8,9};            // Relay output pins

// statics
#define RELAYDELAY 1800000                  // How long to open door lock once access is granted. (1000 = 1sec)
#define RELAYPIN1 relayPins[0]           // Define the pin for electrified door 1 hardware
#define RELAYPIN2 relayPins[2]           // Define the pin for electrified door 2 hardware

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


// initialize the library with the numbers of the interface pins
LiquidCrystal lcd(12, 11, 5, 4, 3, 2);

// strings for storing results from web server
String httpresponse = "";
String username = "";

// variables for storing system status
volatile long reader1 = 0;
volatile int  reader1Count = 0;
bool authorized = false;
bool relay1high = false; 
bool relay2high = false;
unsigned long relay1timer=0;


void setup(){           // Runs once at Arduino boot-up

  /* Attach pin change interrupt service routines from the Wiegand RFID readers
   */
  pcattach.PCattachInterrupt(reader1Pins[0], callReader1Zero, CHANGE); 
  pcattach.PCattachInterrupt(reader1Pins[1], callReader1One,  CHANGE);  

  //Clear and initialize readers
  wiegand26.initReaderOne(); //Set up Reader 1 and clear buffers.

  //Initialize output relays
  for(byte i=0; i<4; i++){        
    pinMode(relayPins[i], OUTPUT);                                                      
    digitalWrite(relayPins[i], LOW);                  // Sets the relay outputs to LOW (relays off)
  }

  Serial.begin(57600);	               	       // Set up Serial output at 8,N,1,57600bps
  
  // start the Ethernet connection:
  Ethernet.begin(mac, ip);
  
  // set up the LCD's number of columns and rows: 
  lcd.begin(10, 2);
  // Print a message to the LCD.
  lcd.print("hI");

}
void loop()                                     // Main branch, runs over and over again
{ 
  // set the cursor to column 0, line 1
  // (note: line 1 is the second row, since counting begins with 0):
  lcd.setCursor(0, 1);
  // print the number of seconds since reset:
  lcd.print(millis()/1000);
  
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
    Serial.println(e);
    
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
  
  // check timer -- if expired, remove authorization
  
  if(authorized && relay1high) {
    // calculate current time elapsed
    long currentTime = millis() - relay1timer;
    // if time entirely elapsed, deauthorize.
    if(currentTime >= RELAYDELAY) {
      authorized = false;
    }
    
    // calculate for display
    long remaining = (RELAYDELAY - currentTime) / 1000;
    long secRemaining = (RELAYDELAY - currentTime) / 1000 % 60;
    long minRemaining = (RELAYDELAY - currentTime) / 1000 / 60 % 60;
    long hrsRemaining = (RELAYDELAY - currentTime) / 1000 / 60 / 60;

    // display timer & username
    Serial.print(hrsRemaining);
    Serial.print(":");
    Serial.print(minRemaining);
    Serial.print(":");
    Serial.print(secRemaining);
    Serial.print(" remaining, ");
    Serial.println(username);
  }
  if(!authorized && relay1high) {
    // not authorized -- turn off relay
    relayLow(1);
  }
  if(authorized && !relay1high) {
    // authorized -- turn on relay
    relayHigh(1);
  }
  if(!authorized && !relay1high) {
    // display login message
    Serial.println("Please login.");
  }
  
} // End of loop()




/* Access System Functions - Modify these as needed for your application. 
 These function control lock/unlock and user lookup.
 */

void relayHigh(int input) {          //Send an unlock signal to the door and flash the Door LED

relay1timer = millis();

byte dp=1;
  if(input == 1) {
    dp=RELAYPIN1; }
  if(input == 2) {
    dp=RELAYPIN2; }
  
  digitalWrite(dp, HIGH);
  
  if (input == 1) {
    relay1high = true;
  }
  if (input == 2) {
    relay2high = true; 
  }
  
  Serial.print("Relay ");
  Serial.print(input,DEC);
  Serial.println(" high");

}

void relayLow(int input) {          //Send an unlock signal to the door and flash the Door LED
byte dp=1;
  if(input == 1) {
    dp=RELAYPIN1; }
  if(input == 2) {
    dp=RELAYPIN2; }

  digitalWrite(dp, LOW);

  if (input == 1) {
    relay1high = false;
  }
  if (input == 2) {
    relay2high = false; 
  }

  Serial.print("Relay ");
  Serial.print(input,DEC);
  Serial.println(" low");

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


