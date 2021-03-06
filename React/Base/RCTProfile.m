/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "RCTProfile.h"

#import <mach/mach.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import <UIKit/UIKit.h>

#import "RCTAssert.h"
#import "RCTBridge.h"
#import "RCTDefines.h"
#import "RCTModuleData.h"
#import "RCTUtils.h"

NSString *const RCTProfileDidStartProfiling = @"RCTProfileDidStartProfiling";
NSString *const RCTProfileDidEndProfiling = @"RCTProfileDidEndProfiling";

#if RCT_DEV

#pragma mark - Prototypes

NSNumber *RCTProfileTimestamp(NSTimeInterval);
NSString *RCTProfileMemory(vm_size_t);
NSDictionary *RCTProfileGetMemoryUsage(BOOL);

#pragma mark - Constants

NSString const *RCTProfileTraceEvents = @"traceEvents";
NSString const *RCTProfileSamples = @"samples";
NSString *const RCTProfilePrefix = @"rct_profile_";

#pragma mark - Variables

NSDictionary *RCTProfileInfo;
NSUInteger RCTProfileEventID = 0;
NSMutableDictionary *RCTProfileOngoingEvents;
NSTimeInterval RCTProfileStartTime;
NSRecursiveLock *_RCTProfileLock;

#pragma mark - Macros

#define RCTProfileAddEvent(type, props...) \
[RCTProfileInfo[type] addObject:@{ \
  @"pid": @([[NSProcessInfo processInfo] processIdentifier]), \
  @"tid": RCTCurrentThreadName(), \
  props \
}];

#define CHECK(...) \
if (!RCTProfileIsProfiling()) { \
  return __VA_ARGS__; \
}

#define RCTProfileLock(...) \
[_RCTProfileLock lock]; \
__VA_ARGS__ \
[_RCTProfileLock unlock]

#pragma mark - Private Helpers

NSNumber *RCTProfileTimestamp(NSTimeInterval timestamp)
{
  return @((timestamp - RCTProfileStartTime) * 1e6);
}

NSString *RCTProfileMemory(vm_size_t memory)
{
  double mem = ((double)memory) / 1024 / 1024;
  return [NSString stringWithFormat:@"%.2lfmb", mem];
}


NSDictionary *RCTProfileGetMemoryUsage(BOOL raw)
{
  struct task_basic_info info;
  mach_msg_type_number_t size = sizeof(info);
  kern_return_t kerr = task_info(mach_task_self(),
                                 TASK_BASIC_INFO,
                                 (task_info_t)&info,
                                 &size);
  if( kerr == KERN_SUCCESS ) {
    vm_size_t vs = info.virtual_size;
    vm_size_t rs = info.resident_size;
    return @{
      @"suspend_count": @(info.suspend_count),
      @"virtual_size": raw ? @(vs) : RCTProfileMemory(vs),
      @"resident_size": raw ? @(rs) : RCTProfileMemory(rs),
    };
  } else {
    return @{};
  }

}

NSNumber *RCTProfileGetCPUUsage(void)
{
  kern_return_t kr;
  task_info_data_t tinfo;
  mach_msg_type_number_t task_info_count;

  task_info_count = TASK_INFO_MAX;
  kr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)tinfo, &task_info_count);
  if (kr != KERN_SUCCESS) {
    return nil;
  }

  thread_array_t thread_list;
  mach_msg_type_number_t thread_count;

  thread_info_data_t thinfo;
  mach_msg_type_number_t thread_info_count;

  thread_basic_info_t basic_info_th;

  // get threads in the task
  kr = task_threads(mach_task_self(), &thread_list, &thread_count);
  if (kr != KERN_SUCCESS) {
    return nil;
  }

  long tot_sec = 0;
  long tot_usec = 0;
  float tot_cpu = 0;
  unsigned j;

  for (j = 0; j < thread_count; j++) {
    thread_info_count = THREAD_INFO_MAX;
    kr = thread_info(thread_list[j], THREAD_BASIC_INFO,
                     (thread_info_t)thinfo, &thread_info_count);
    if (kr != KERN_SUCCESS) {
      return nil;
    }

    basic_info_th = (thread_basic_info_t)thinfo;

    if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
      tot_sec = tot_sec + basic_info_th->user_time.seconds + basic_info_th->system_time.seconds;
      tot_usec = tot_usec + basic_info_th->system_time.microseconds + basic_info_th->system_time.microseconds;
      tot_cpu = tot_cpu + basic_info_th->cpu_usage / (float)TH_USAGE_SCALE * 100.0;
    }

  } // for each thread

  kr = vm_deallocate(mach_task_self(), (vm_offset_t)thread_list, thread_count * sizeof(thread_t));

  if( kr == KERN_SUCCESS ) {
    return [NSNumber numberWithFloat:tot_cpu];
  } else {
    return nil;

  }
}

#pragma mark - Module hooks

static const char *RCTProfileProxyClassName(Class);
static const char *RCTProfileProxyClassName(Class class)
{
  return [RCTProfilePrefix stringByAppendingString:NSStringFromClass(class)].UTF8String;
}

static SEL RCTProfileProxySelector(SEL);
static SEL RCTProfileProxySelector(SEL selector)
{
  NSString *selectorName = NSStringFromSelector(selector);
  return NSSelectorFromString([RCTProfilePrefix stringByAppendingString:selectorName]);
}

static void RCTProfileForwardInvocation(NSObject *, SEL, NSInvocation *);
static void RCTProfileForwardInvocation(NSObject *self, __unused SEL cmd, NSInvocation *invocation)
{
  NSString *name = [NSString stringWithFormat:@"-[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(invocation.selector)];
  SEL newSel = RCTProfileProxySelector(invocation.selector);

  RCTProfileLock(
    if ([object_getClass(self) instancesRespondToSelector:newSel]) {
      invocation.selector = newSel;
      RCTProfileBeginEvent();
      [invocation invoke];
      RCTProfileEndEvent(name, @"objc_call,modules,auto", nil);
    } else {
      // Use original selector to don't change error message
      [self doesNotRecognizeSelector:invocation.selector];
    }
  );
}

static IMP RCTProfileMsgForward(NSObject *, SEL);
static IMP RCTProfileMsgForward(NSObject *self, SEL selector)
{
  IMP imp = _objc_msgForward;
#if !defined(__arm64__)
  NSMethodSignature *signature = [self methodSignatureForSelector:selector];
  if (signature.methodReturnType[0] == _C_STRUCT_B && signature.methodReturnLength > 8) {
    imp = _objc_msgForward_stret;
  }
#endif
  return imp;
}

static void RCTProfileHookModules(RCTBridge *);
static void RCTProfileHookModules(RCTBridge *bridge)
{
  for (RCTModuleData *moduleData in [bridge valueForKey:@"_modules"]) {
    [moduleData dispatchBlock:^{
      Class moduleClass = moduleData.cls;
      Class proxyClass = objc_allocateClassPair(moduleClass, RCTProfileProxyClassName(moduleClass), 0);

      unsigned int methodCount;
      Method *methods = class_copyMethodList(moduleClass, &methodCount);
      for (NSUInteger i = 0; i < methodCount; i++) {
        Method method = methods[i];
        SEL selector = method_getName(method);
        if ([NSStringFromSelector(selector) hasPrefix:@"rct"] || [NSObject instancesRespondToSelector:selector]) {
          continue;
        }
        IMP originalIMP = method_getImplementation(method);
        const char *returnType = method_getTypeEncoding(method);
        class_addMethod(proxyClass, selector, RCTProfileMsgForward(moduleData.instance, selector), returnType);
        class_addMethod(proxyClass, RCTProfileProxySelector(selector), originalIMP, returnType);
      }
      free(methods);

      class_replaceMethod(object_getClass(proxyClass), @selector(initialize), imp_implementationWithBlock(^{}), "v@:");

      for (Class cls in @[proxyClass, object_getClass(proxyClass)]) {
        Method oldImp = class_getInstanceMethod(cls, @selector(class));
        class_replaceMethod(cls, @selector(class), imp_implementationWithBlock(^{ return moduleClass; }), method_getTypeEncoding(oldImp));
      }

      IMP originalFwd = class_replaceMethod(moduleClass, @selector(forwardInvocation:), (IMP)RCTProfileForwardInvocation, "v@:@");
      if (originalFwd != NULL) {
        class_addMethod(proxyClass, RCTProfileProxySelector(@selector(forwardInvocation:)), originalFwd, "v@:@");
      }

      objc_registerClassPair(proxyClass);
      object_setClass(moduleData.instance, proxyClass);
    }];
  }
}

void RCTProfileUnhookModules(RCTBridge *);
void RCTProfileUnhookModules(RCTBridge *bridge)
{
  for (RCTModuleData *moduleData in [bridge valueForKey:@"_modules"]) {
    [moduleData dispatchBlock:^{
      RCTProfileLock(
        Class proxyClass = object_getClass(moduleData.instance);
        if (moduleData.cls != proxyClass) {
          object_setClass(moduleData.instance, moduleData.cls);
          objc_disposeClassPair(proxyClass);
        }
      );
    }];
  };
}


#pragma mark - Public Functions

BOOL RCTProfileIsProfiling(void)
{
  RCTProfileLock(
    BOOL profiling = RCTProfileInfo != nil;
  );
  return profiling;
}

void RCTProfileInit(RCTBridge *bridge)
{
  RCTProfileHookModules(bridge);

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    _RCTProfileLock = [[NSRecursiveLock alloc] init];
  });
  RCTProfileLock(
    RCTProfileStartTime = CACurrentMediaTime();
    RCTProfileOngoingEvents = [[NSMutableDictionary alloc] init];
    RCTProfileInfo = @{
      RCTProfileTraceEvents: [[NSMutableArray alloc] init],
      RCTProfileSamples: [[NSMutableArray alloc] init],
    };
  );

  [[NSNotificationCenter defaultCenter] postNotificationName:RCTProfileDidStartProfiling
                                                      object:nil];
}

NSString *RCTProfileEnd(RCTBridge *bridge)
{
  [[NSNotificationCenter defaultCenter] postNotificationName:RCTProfileDidEndProfiling
                                                      object:nil];

  RCTProfileLock(
    NSString *log = RCTJSONStringify(RCTProfileInfo, NULL);
    RCTProfileEventID = 0;
    RCTProfileInfo = nil;
    RCTProfileOngoingEvents = nil;
  );

  RCTProfileUnhookModules(bridge);

  return log;
}

NSNumber *_RCTProfileBeginEvent(void)
{
  CHECK(@0);
  RCTProfileLock(
    NSNumber *eventID = @(++RCTProfileEventID);
    RCTProfileOngoingEvents[eventID] = RCTProfileTimestamp(CACurrentMediaTime());
  );
  return eventID;
}

void _RCTProfileEndEvent(NSNumber *eventID, NSString *name, NSString *categories, id args)
{
  CHECK();
  RCTProfileLock(
    NSNumber *startTimestamp = RCTProfileOngoingEvents[eventID];
    if (startTimestamp) {
      NSNumber *endTimestamp = RCTProfileTimestamp(CACurrentMediaTime());

      RCTProfileAddEvent(RCTProfileTraceEvents,
        @"name": name,
        @"cat": categories,
        @"ph": @"X",
        @"ts": startTimestamp,
        @"dur": @(endTimestamp.doubleValue - startTimestamp.doubleValue),
        @"args": args ?: @[],
      );
      [RCTProfileOngoingEvents removeObjectForKey:eventID];
    }
  );
}

void RCTProfileImmediateEvent(NSString *name, NSTimeInterval timestamp, NSString *scope)
{
  CHECK();
  RCTProfileLock(
    RCTProfileAddEvent(RCTProfileTraceEvents,
      @"name": name,
      @"ts": RCTProfileTimestamp(timestamp),
      @"scope": scope,
      @"ph": @"i",
      @"args": RCTProfileGetMemoryUsage(NO),
    );
  );
}

NSNumber *_RCTProfileBeginFlowEvent(void)
{
  static NSUInteger flowID = 0;

  CHECK(@0);
  RCTProfileAddEvent(RCTProfileTraceEvents,
    @"name": @"flow",
    @"id": @(++flowID),
    @"cat": @"flow",
    @"ph": @"s",
    @"ts": RCTProfileTimestamp(CACurrentMediaTime()),
  );

  return @(flowID);
}

void _RCTProfileEndFlowEvent(NSNumber *flowID)
{
  CHECK();
  RCTProfileAddEvent(RCTProfileTraceEvents,
    @"name": @"flow",
    @"id": flowID,
    @"cat": @"flow",
    @"ph": @"f",
    @"ts": RCTProfileTimestamp(CACurrentMediaTime()),
  );
}

#endif
