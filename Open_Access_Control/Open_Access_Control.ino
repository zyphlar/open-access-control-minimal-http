/*
 * Open Source RFID Access Controller - MINIMAL HTTP EDITION
 * AKA RFID Interlock
 *
 * 02/23/2014 v0.1
 * Last build test with Arduino v1.00
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
 * Relay output on digital pin 7
 * RFID Reader: pins 2,3
 * Ethernet: pins 10,11,12,13 (reserved for the Ethernet shield)
 * LCD: pins 4, 5, 6
 * Warning buzzer: 8
 * Warning LED: 9
 * Extend button: A5
 * Logout button: A4
 *
 * Quickstart tips: 
 * Compile and upload the code, then log in via serial console at 57600,8,N,1
 *
 */
 

/////////////////
// BEGIN USER CONFIGURATION SECTION
/////////////////

// Enter a MAC address, server address, and device identifier for your controller below.
// The IP address will be automatically assigned via DHCP.
char* device = "laser";                       // device identifier (aka "certification slug")
char* server = "members.heatsynclabs.org";    // authorization server (typically Open Access Control Web Interface)
char* user = "YOUREMAILORUSERNAME";        // username to login to server
char* pass = "YOURPASSWORD";                        // password to login to server
byte mac[] = {  0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xAD };

/////////////////
// END USER CONFIGURATION SECTION
/////////////////


// Includes
#include <EEPROM.h>       // Needed for saving to non-voilatile memory on the Arduino.

#include <Ethernet.h>
#include <SPI.h>          
#include <Server.h>
#include <Client.h>

#include <WIEGAND26.h>    // Wiegand 26 reader format libary
#include <PCATTACH.h>     // Pcint.h implementation, allows for >2 software interupts.
#include <ShiftLCD.h>     // LCD via shift register

// Create an instance of the various C++ libraries we are using.
WIEGAND26 wiegand26;  // Wiegand26 (RFID reader serial protocol) library
PCATTACH pcattach;    // Software interrupt library

// pin assignments
byte reader1Pins[]={2,3};               // Reader 1 pins
byte RELAYPIN1 = 7;
byte buzzerPin = 8;
byte warningLED = 9;
byte extendButton = A5;
byte logoutButton = A4;

// initialize the ShiftLCD library with the numbers of the interface pins
ShiftLCD lcd(4, 5, 6);

// statics
#define RELAYDELAY 1800000                  // How long to open door lock once access is granted. (1000 = 1sec)

// Serial terminal buffer (needs to be global)
char inString[40]={0};                                         // Size of command buffer (<=128 for Arduino)
byte inCount=0;
boolean privmodeEnabled = false;                               // Switch for enabling "priveleged" commands

// Initialize the Ethernet client library
EthernetClient client;

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
int extendButtonDebounce = 0;


void setup(){           // Runs once at Arduino boot-up

  /* Attach pin change interrupt service routines from the Wiegand RFID readers
   */
  pcattach.PCattachInterrupt(reader1Pins[0], callReader1Zero, CHANGE); 
  pcattach.PCattachInterrupt(reader1Pins[1], callReader1One,  CHANGE);  
  
  //Clear and initialize readers
  wiegand26.initReaderOne(); //Set up Reader 1 and clear buffers.

  // Initialize button input
  pinMode(extendButton, INPUT);
  digitalWrite(extendButton, HIGH);
  pinMode(logoutButton, INPUT);
  digitalWrite(logoutButton, HIGH);
  
  // Initialize led and buzzer
  pinMode(warningLED, OUTPUT);                                                      
  digitalWrite(warningLED, LOW);                  
  pinMode(buzzerPin, OUTPUT);                                                      
  digitalWrite(buzzerPin, LOW);   

  //Initialize output relays
  pinMode(RELAYPIN1, OUTPUT);                                                      
  digitalWrite(RELAYPIN1, LOW);                  // Sets the relay outputs to LOW (relays off)

  Serial.begin(57600);	               	       // Set up Serial output at 8,N,1,57600bps
  
  // set up the LCD's number of rows and columns: 
  lcd.begin(16, 2);
  lcdprint(0,0,"Starting...");
  
  // start the Ethernet connection:
  if (Ethernet.begin(mac) == 0) {
    lcd.clear();
    lcdprint(0,0,"FAIL: No Network");
    lcdprint(0,1,"Chk DHCP, Reboot");
    // no point in carrying on, so do nothing forevermore:
    for(;;)
      ;
  }
  else {
    lcd.clear();
    lcdprint(0,0,"Found IP:");
    
    Serial.println(Ethernet.localIP());
    lcd.setCursor(0, 1);
    lcd.print(Ethernet.localIP());
  }
  // give the Ethernet shield a second to initialize:
  delay(1000);
  
  lcd.clear();

}
void loop()                                     // Main branch, runs over and over again
{ 
  
  //////////////////////////
  // Normal operation section
  //////////////////////////  
  
  // check timer -- if expired, remove authorization
  
  if(authorized && relay1high) {
   
    // Detect logout button push
    if (analogRead(logoutButton) < 50) {  
      Serial.println("logout");
      authorized = false;
    }
    
    // Detect extend button push with debounce/repeat
    if (analogRead(extendButton) < 50) {  
      extendButtonDebounce++;
    } else {
      extendButtonDebounce = 0;
    } 
    if(extendButtonDebounce > 5){
      Serial.println("extend");
      relay1timer += RELAYDELAY; 
      extendButtonDebounce = -15; 
    }
    
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
    lcd.setCursor(0, 0);    
    lcd.print(username);
    lcd.setCursor(0, 1);
    lcd.print(hrsRemaining);
    lcd.print(":");
    lcd.print(minRemaining);
    lcd.print(":");
    lcd.print(secRemaining);
    lcd.print(" remain    ");
       
    if(remaining == 300) {
      for(int berp=0; berp<3; berp++){
        tone(buzzerPin, 784, 300); 
        delay(300);
        digitalWrite(warningLED, HIGH);
        tone(buzzerPin, 659, 600); 
        lcd.setCursor(15, 1);        
        lcd.print("!");
        delay(1000);
        digitalWrite(warningLED, LOW);        
        lcd.setCursor(15, 1);        
        lcd.print(" ");
      }
    }
    
    if(remaining == 60) {
      for(int berp=0; berp<5; berp++){
        digitalWrite(warningLED, HIGH);
        lcd.setCursor(15, 1);        
        lcd.print("!");
        tone(buzzerPin, 1047, 100); 
        delay(130);
        tone(buzzerPin, 1109, 100); 
        delay(130);
        tone(buzzerPin, 1109, 100); 
        delay(130);
        tone(buzzerPin, 1109, 100); 
        digitalWrite(warningLED, LOW);
        delay(500);
      }
    }
    
    if(remaining == 15) {
      for(int berp=0; berp<4; berp++){
        digitalWrite(warningLED, HIGH);
        tone(buzzerPin, 1661, 800); 
        delay(800);
        digitalWrite(warningLED, LOW);
        delay(200);
      }
    }
  }
  if(!authorized && relay1high) {
    lcd.clear();
    lcdprint(0,0,"Turning off.");
    delay(500);    
    lcd.clear();    
    
    // not authorized -- turn off relay
    relayLow(1);
    wiegand26.initReaderOne();                     // Reset for next tag scan  
  }
  if(authorized && !relay1high) {
    lcd.clear();
    lcdprint(0,0,"Turning on.");
    delay(500);
    lcd.clear();

    // authorized -- turn on relay
    relayHigh(1);
    wiegand26.initReaderOne();                     // Reset for next tag scan  
  }
  if(!authorized && !relay1high) {
    // display login message
    lcd.setCursor(0,0);
    lcd.print("Please login.");
      
    //////////////////////////  
    // Reader input/authentication section  
    //////////////////////////
    if(reader1Count >= 26)
    {                           //  When tag presented to reader1 (No keypad on this reader)
       
       Serial.print("Reader 1: ");
       Serial.println(reader1, HEX);
       lcdprint(0,0,"connecting...");
       delay(150);
    
       // if you get a connection, report back via serial:
       if (client.connect(server, 80))
       {
         lcd.clear();
         lcdprint(0,0,"connected");
         
         Serial.print("GET /cards/authorize/");   
         Serial.print(reader1, HEX);
         Serial.print("?device=");
         Serial.print(device);
         Serial.print("&user=");
         Serial.print(user);
         Serial.print("&pass=");
         Serial.print(pass);
         Serial.println(" HTTP/1.0");
         Serial.print("Host: ");
         Serial.println(server);
         Serial.println();
          
         client.print("GET /cards/authorize/");   
         client.print(reader1, HEX);
         client.print("?device=");
         client.print(device);
         client.print("&user=");
         client.print(user);
         client.print("&pass=");
         client.print(pass);
         client.println(" HTTP/1.0");
         client.print("Host: ");
         client.println(server);
         client.println();
  
         // reset values coming from http
         httpresponse = "";
         username = "";
         authorized = false;
       }
       else 
       {
         // if you didn't get a connection to the server:
         Serial.println("connection failed");
         lcd.clear();
         lcdprint(0,0,"connection failed");
         delay(500);
         lcd.clear();
       }
       
       wiegand26.initReaderOne();                     // Reset for next tag scan  
       
    }
  
    
    while (client.available()) {
      char thisChar = client.read();
      Serial.print(thisChar);
      // only fill up httpresponse with data after a [ sign.
      // limit total text to 50 to prevent buffer issues
      if ((httpresponse.charAt(0) == '[' || thisChar == '[')  && httpresponse.length() < 50) { 
        httpresponse += thisChar;
      }
    }
    
    if(!client.available() && httpresponse.length()>0) { 
      Serial.println("Response: ");
      
      Serial.println(httpresponse);
      int c = httpresponse.indexOf('[');
      int d = httpresponse.indexOf(',');
      int e = httpresponse.indexOf(']');
      
      Serial.print("IndexOf:");
      Serial.println(c);
      Serial.println(d);
      Serial.println(e);
      
      Serial.println("AuthSubStr:");
      Serial.println(httpresponse.substring(c+1,d));
      
      if(httpresponse.substring(c+1,d) == "true") {
        authorized = true; 
      }
      else {
        Serial.println(httpresponse.substring(c+1,d));
      }
      
      Serial.print("Auth: ");
      Serial.println(authorized);
      
      
      Serial.println("UserSubStr:");
      Serial.println(httpresponse.substring(d+1,e));
  
      String username_raw = httpresponse.substring(d+1,e);
      username_raw.replace("\"", "");
      Serial.print("UserTrimmed: ");
      Serial.println(username_raw);
  
      username = username_raw;
      
      Serial.print("User: ");
      Serial.println(username);
      
      
      Serial.println("End Response");
      httpresponse = "";
      
      if(!authorized) {
        lcd.clear();
        lcdprint(0,0,"Not authorized.");
        delay(500);
      }
    }
    
    // if the server's disconnected, stop the client:
    if (!client.connected()) {
      client.stop();
    }
    
  }
  
  
} // End of loop()


void lcdprint(int x, int y, char* text) {
  Serial.println(text);
  // set the cursor to column 0, line 1
  // (note: line 1 is the second row, since counting begins with 0):
  lcd.setCursor(x, y);
  // print the number of seconds since reset:
  lcd.print(text);
}

/* Access System Functions - Modify these as needed for your application. 
 These function control lock/unlock and user lookup.
 */

void relayHigh(int input) {          //Send an unlock signal to the door and flash the Door LED

relay1timer = millis();

byte dp=1;
  if(input == 1) {
    dp=RELAYPIN1; }
    
  digitalWrite(dp, HIGH);
  
  if (input == 1) {
    relay1high = true;
  }
  
  Serial.print("Relay ");
  Serial.print(input,DEC);
  Serial.println(" high");

}

void relayLow(int input) {          //Send an unlock signal to the door and flash the Door LED
byte dp=1;
  if(input == 1) {
    dp=RELAYPIN1; }

  digitalWrite(dp, LOW);

  if (input == 1) {
    relay1high = false;
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


