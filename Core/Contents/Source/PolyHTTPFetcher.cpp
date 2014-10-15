/*
Copyright (C) 2014 by Joachim Meyer

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/

#include "PolyHTTPFetcher.h"
#include "PolyLogger.h"
#include "PolyTimer.h"
#include "Ws2tcpip.h"

using namespace Polycode;

HTTPFetcher::HTTPFetcher(String address) : EventDispatcher() {
	this->address = address;
	int protocolIndex = address.find_first_of("://");
	if (protocolIndex != NULL){
		protocolIndex += strlen("://");
		pathIndex = address.find_first_of("/", protocolIndex);
		
		if (pathIndex != 0){
			host = address.substr(protocolIndex, pathIndex - protocolIndex);
		} else {
			host = address.substr(protocolIndex, address.length());
		}
	} else {
		pathIndex = address.find_first_of("/");

		if (pathIndex != 0){
			host = address.substr(0, pathIndex);
		} else {
			host = address;
		}
	}

	struct sockaddr_in server;
		
	addrinfo *result = NULL;
	addrinfo *ptr = NULL;
	addrinfo hints;

	char ipstringbuffer[46];
	unsigned long ipbufferlength = 46;

	//Create a socket
	if ((s = socket(AF_INET, SOCK_STREAM, 0)) == INVALID_SOCKET) {
		Logger::log("HTTP Fetcher: Could not create socket: %d\n", WSAGetLastError());
	}
	
	ZeroMemory(&hints, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_protocol = IPPROTO_TCP;
	
	if (getaddrinfo(host.c_str(), address.substr(0, protocolIndex - strlen("://")).c_str(), &hints, &result) != 0) {
		Logger::log("HTTP Fetcher: Address resolve error: %d\n", WSAGetLastError());
		return;
	}
	
#ifdef _WINDOWS
	if (WSAAddressToStringA(result->ai_addr, (unsigned long)result->ai_addrlen, NULL, ipstringbuffer, &ipbufferlength) != 0) {
		Logger::log("HTTP Fetcher: Address to String convert error: %d\n", WSAGetLastError());
		return;
	}
#endif

	String ipString = ipstringbuffer;
	ipString = ipString.substr(0, ipString.find_first_of(":"));

	server.sin_addr.s_addr = inet_addr(ipString.c_str());
	server.sin_family = AF_INET;
	server.sin_port = htons(80);

	//Connect to remote server
	if (connect(s, (struct sockaddr *)&server, sizeof(server)) < 0) {
		Logger::log("HTTP Fetcher: connect error code: %d\n", WSAGetLastError());
		return;
	}
}

HTTPFetcher::~HTTPFetcher(){}

bool HTTPFetcher::receiveHTTPData(){

	//Send some data
	String request;
	if (pathIndex) {
		//request = "GET /updater.xml HTTP/1.1\r\n" + String("Host: dl.war-of-universe.com\r\n") + String("Connection: close\r\n\r\n"); //+ String("Accept-Charset: ISO-8859-1,UTF-8;q=0.7,*;q=0.7");
		request = "GET " + address.substr(pathIndex, address.length()) + " " + String(HTTP_VERSION) + "\r\nHost: " + host + "\r\nUser-Agent: " + DEFAULT_USER_AGENT + "\r\nConnection: close\r\n\r\n";
	} else {
		request = "GET / " + String(HTTP_VERSION) + "\r\nHost: " + host + "\r\nUser-Agent: " + DEFAULT_USER_AGENT + "\r\nConnection: close\r\n\r\n";
	}
	if (send(s, request.c_str(), strlen(request.c_str()), 0) < 0) {
		Logger::log("HTTP Fetcher: Send failed %d\n", WSAGetLastError());
		return false;
	}

	char server_reply[DEFAULT_PAGE_BUF_SIZE];
	unsigned long recv_size;
	//Receive a reply from the server
	if ((recv_size = recv(s, server_reply, 2000, 0)) == SOCKET_ERROR) {
		Logger::log("HTTP Fetcher: recv failed %d\n", WSAGetLastError());
		return false;
	}

	//Add a NULL terminating character to make it a proper string before printing
	server_reply[recv_size] = '\0';

	HTTPFetcherEvent *event = new HTTPFetcherEvent();
	event->data = server_reply;
	char *charIndex = strstr(event->data, "HTTP/");
	int i;
	if (sscanf(charIndex, "HTTP/1.1 %d", &i) != 1 || i < 200 || i>299) {
		return false;
	}
	charIndex = strstr(event->data, "Content-Length:");
	if (charIndex == NULL)
		charIndex = strstr(event->data, "Content-length:");
	if (sscanf(charIndex + strlen("content-length: "), "%d", &i) != 1) {
		return false;
	}

	charIndex = strstr(event->data, "\r\n\r\n") + strlen("\r\n\r\n");

	event->data = charIndex;
	bodyReturn = String(charIndex);
	dispatchEvent(event, HTTPFetcherEvent::EVENT_HTTP_DATA_RECEIVED);
	return true;
}

String HTTPFetcher::getData(){
	return this->bodyReturn;
}