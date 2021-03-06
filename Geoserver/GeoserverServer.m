// GeoserverServer.m
//
// Created by Mattt Thompson (http://mattt.me/)
// Copyright (c) 2012 Heroku (http://heroku.com/)
// 
// Portions Copyright (c) 1996-2012, The PostgreSQL Global Development Group
// Portions Copyright (c) 1994, The Regents of the University of California
//
// Permission to use, copy, modify, and distribute this software and its
// documentation for any purpose, without fee, and without a written agreement
// is hereby granted, provided that the above copyright notice and this
// paragraph and the following two paragraphs appear in all copies.
//
// IN NO EVENT SHALL THE UNIVERSITY OF CALIFORNIA BE LIABLE TO ANY PARTY FOR
// DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, INCLUDING
// LOST PROFITS, ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION,
// EVEN IF THE UNIVERSITY OF CALIFORNIA HAS BEEN ADVISED OF THE POSSIBILITY OF
// SUCH DAMAGE.
//
// THE UNIVERSITY OF CALIFORNIA SPECIFICALLY DISCLAIMS ANY WARRANTIES,
// INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
// FITNESS FOR A PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON AN
// "AS IS" BASIS, AND THE UNIVERSITY OF CALIFORNIA HAS NO OBLIGATIONS TO
// PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.

#import <xpc/xpc.h>
#import "GeoserverServer.h"
#import "NSFileManager+DirectoryLocations.h"
#import "GeoserverSettings.h"

@implementation GeoserverServer {
    __strong NSString *_binPath;
    __strong NSString *_dataPath;
    __strong NSTask *_geoserverTask;
    NSUInteger _port;
    BOOL _isRunning;
    NSString *_javaHome;
    NSString *_javaCmd;
    
    xpc_connection_t _xpc_connection;
}

+ (GeoserverServer *)sharedServer {
    static GeoserverServer *_sharedServer = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedServer = [[GeoserverServer alloc] initWithExecutablesDirectory:[[NSBundle mainBundle] pathForAuxiliaryExecutable:@"jetty"] dataDirectory:[[[NSFileManager defaultManager] applicationSupportDirectory] stringByAppendingPathComponent:@"jetty"]];
    });
    
    return _sharedServer;
}

- (id)initWithExecutablesDirectory:(NSString *)executablesDirectory
                 dataDirectory:(NSString *)dataDirectory
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _binPath = executablesDirectory;
    _dataPath = dataDirectory;
    _javaHome = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"jre"];
    _javaCmd = [NSString stringWithFormat:@"%@/bin/java",_javaHome];
    
    _xpc_connection = xpc_connection_create("com.boundlessgeo.geoserver-service", dispatch_get_main_queue());
	xpc_connection_set_event_handler(_xpc_connection, ^(xpc_object_t event) {        
        xpc_dictionary_apply(event, ^bool(const char *key, xpc_object_t value) {
			return true;
		});
	});
	xpc_connection_resume(_xpc_connection);
    
    return self;
}

- (NSUInteger)port {
    return [self isRunning] ? _port : NSNotFound;
}

- (BOOL)isRunning {
    if (!_isRunning) {
        NSError* error = nil;
        NSURLResponse* response = nil;
        NSURL* requestUrl = [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%lu/geoserver",(unsigned long)_port]];
        NSURLRequest* request = [NSURLRequest requestWithURL:requestUrl];
        [NSURLConnection sendSynchronousRequest:request
                                                 returningResponse:&response error:&error];
        if (error) {
            return NO;
        }
    }
    
    return YES;
}

- (BOOL)startOnPort:(NSUInteger)port 
 terminationHandler:(void (^)(NSUInteger status))completionBlock
{    
    [self willChangeValueForKey:@"isRunning"];
    [self willChangeValueForKey:@"port"];
    _port = port;
    
    [self executeCommandNamed:_javaCmd arguments:@[@"-jar", [NSString stringWithFormat:@"%@/start.jar", _dataPath], @"-Djava.awt.headless=true"] terminationHandler:^(NSUInteger status) {
        if (completionBlock) {
            completionBlock(status);
        }
    }];
    
    [self didChangeValueForKey:@"port"];
    [self didChangeValueForKey:@"isRunning"];
    
    return YES;
}

- (BOOL)stopWithTerminationHandler:(void (^)(NSUInteger status))terminationHandler {
    [self executeCommandNamed:_javaCmd arguments:@[@"-jar", [NSString stringWithFormat:@"%@/start.jar", _dataPath], @"-Djava.awt.headless=true", @"--stop"] terminationHandler:terminationHandler];
    
    return YES;
}

- (void)executeCommandNamed:(NSString *)command 
                  arguments:(NSArray *)arguments
         terminationHandler:(void (^)(NSUInteger status))terminationHandler
{
	xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);

    xpc_dictionary_set_string(message, "command", [command UTF8String]);
    
    xpc_object_t args = xpc_array_create(NULL, 0);
    [arguments enumerateObjectsUsingBlock:^(id argument, NSUInteger idx, BOOL *stop) {
        xpc_array_set_value(args, XPC_ARRAY_APPEND, xpc_string_create([argument UTF8String]));
    }];
    xpc_dictionary_set_value(message, "arguments", args);
    xpc_dictionary_set_string(message, "classpath_root", [_dataPath UTF8String]);
    xpc_dictionary_set_string(message, "gdal_path", [[NSString stringWithFormat:@"%@/gdal", _dataPath] UTF8String]);
    xpc_dictionary_set_string(message, "data_dir", [[[GeoserverSettings sharedSettings] dataDir] UTF8String]);
    xpc_dictionary_set_string(message, "java_home", [_javaHome UTF8String]);
    
    xpc_connection_send_message_with_reply(_xpc_connection, message, dispatch_get_main_queue(), ^(xpc_object_t object) {
        NSLog(@"%lld %s: Status %lld", xpc_dictionary_get_int64(object, "pid"), xpc_dictionary_get_string(object, "command"), xpc_dictionary_get_int64(object, "status"));
        
        if (terminationHandler) {
            terminationHandler(xpc_dictionary_get_int64(object, "status"));
        }
    });
}

@end
