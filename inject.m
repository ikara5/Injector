/*
 *  inject.m
 *  
 *  Created by Sam Bingner on 9/27/2018
 *  Copyright 2018 Sam Bingner. All Rights Reserved.
 *
 */

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include "patchfinder64.h"
#include "CSCommon.h"
#include "kern_funcs.h"

OSStatus SecStaticCodeCreateWithPathAndAttributes(CFURLRef path, SecCSFlags flags, CFDictionaryRef attributes, SecStaticCodeRef  _Nullable *staticCode);
OSStatus SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags, CFDictionaryRef  _Nullable *information);
CFStringRef (*_SecCopyErrorMessageString)(OSStatus status, void * __nullable reserved) = NULL;
 
mach_port_t tfp0 = MACH_PORT_NULL;

enum {
    cdHashTypeSHA1 = 1,
    cdHashTypeSHA256 = 2
};

#define TRUST_CDHASH_LEN (20)
 
struct trust_mem {
    uint64_t next; //struct trust_mem *next;
    unsigned char uuid[16];
    unsigned int count;
    //unsigned char data[];
} __attribute__((packed));

struct hash_entry_t {
    uint16_t num;
    uint16_t start;
} __attribute__((packed));

struct hash_entry_t amfiIndex[0x100];
char *amfiData = NULL;

typedef uint8_t hash_t[TRUST_CDHASH_LEN];

mach_port_t try_restore_port() {
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t err;

    err = host_get_special_port(mach_host_self(), 0, 4, &port);
    if (err == KERN_SUCCESS && port != MACH_PORT_NULL) {
        fprintf(stderr, "got persisted port!\n");
        // make sure rk64 etc use this port
        return port;
    }
    fprintf(stderr, "unable to retrieve persisted port\n");
    return MACH_PORT_NULL;
}

void free_amfitab() {
    if (amfiData != NULL) {
        free(amfiData);
        amfiData = NULL;
    }
}

bool init_amfitab(uint64_t amfitab) {
    if (amfitab == 0)
        return false;

    int rv = kread(amfitab, &amfiIndex, sizeof(amfiIndex));
    size_t len = 0;

    for(int i=0; i<0x100; i++) {
        len += amfiIndex[i].num * 19;
    }
    free_amfitab();
    amfiData = malloc(len);
    rv = kread(amfitab + sizeof(amfiIndex), amfiData, len);
    return true;
}

bool check_amfi(uint64_t amfitab, NSData *hashData) {
    const char *hash = [hashData bytes];
    unsigned char idx = hash[0];
    hash++;
    if (amfiData == NULL && !init_amfitab(amfitab)) {
        return false;
    }
    if (amfiIndex[idx].num == 0 || amfiIndex[idx].start == 0) {
        fprintf(stderr, "Nothing found to check in amficache (wrong?)\n");
        return false;
    }

    char *amfiNext = amfiData + (amfiIndex[idx].start + amfiIndex[idx].num) * 19;
    for (char *amfi = amfiData + amfiIndex[idx].start * 19; amfi < amfiNext; amfi += 19) {
        if (memcmp(hash, amfi, 19) == 0) {
            return true;
        }
    }

    return false;
}

NSArray *filteredHashes(uint64_t trust_chain, NSDictionary *hashes, uint64_t amfitab) {
  NSArray *result;
  @autoreleasepool {
    NSMutableDictionary *filtered = [hashes mutableCopy];
    for (NSData *cdhash in [filtered allKeys]) {
        if (check_amfi(amfitab, cdhash)) {
            printf("%s: already in amfi trustcache, not reinjecting\n", [filtered[cdhash] UTF8String]);
            [filtered removeObjectForKey:cdhash];
        }
    }
    free_amfitab();
    struct trust_mem search;
    search.next = trust_chain;
    while (search.next != 0) {
        uint64_t searchAddr = search.next;
        kread(searchAddr, &search, sizeof(struct trust_mem));
        //printf("Checking %d entries at 0x%llx\n", search.count, searchAddr);
        char *data = malloc(search.count * TRUST_CDHASH_LEN);
        kread(searchAddr + sizeof(struct trust_mem), data, search.count * TRUST_CDHASH_LEN);
        size_t data_size = search.count * TRUST_CDHASH_LEN;

        for (char *dataref = data; dataref <= data + data_size - TRUST_CDHASH_LEN; dataref += TRUST_CDHASH_LEN) {
            NSData *cdhash = [NSData dataWithBytesNoCopy:dataref length:TRUST_CDHASH_LEN freeWhenDone:NO];
            NSString *hashName = filtered[cdhash];
            if (hashName != nil) {
                printf("%s: already in dynamic trustcache, not reinjecting\n", [hashName UTF8String]);
                [filtered removeObjectForKey:cdhash];
                if ([filtered count] == 0) {
                    free(data);
                    return nil;
                }
            }
        }
        free(data);
    }
    printf("Returning %lu keys\n", [[filtered allKeys] count]);
    result = [[filtered allKeys] retain];
  }
  return [result autorelease];
}

int injectTrustCache(int argc, char* argv[], uint64_t trust_chain, uint64_t amficache) {
  @autoreleasepool {
    struct trust_mem mem;
    uint64_t kernel_trust = 0;

    mem.next = rk64(trust_chain);
    mem.count = 0;
    *(uint64_t *)&mem.uuid[0] = 0xabadbabeabadbabe;
    *(uint64_t *)&mem.uuid[8] = 0xabadbabeabadbabe;
    NSMutableDictionary *hashes = [NSMutableDictionary new];
    SecStaticCodeRef staticCode;
    NSDictionary *info;

    for (int i = 1; i < argc; i++) {
        OSStatus result = SecStaticCodeCreateWithPathAndAttributes(CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)@(argv[i]), kCFURLPOSIXPathStyle, false), kSecCSDefaultFlags, NULL, &staticCode);
        if (result != errSecSuccess) {
            if (_SecCopyErrorMessageString != NULL) {
                CFStringRef error = _SecCopyErrorMessageString(result, NULL);
                fprintf(stderr, "Unable to generate cdhash for %s: %s\n", argv[i], [(id)error UTF8String]);
                CFRelease(error);
            } else {
                fprintf(stderr, "Unable to generate cdhash for %s: %d\n", argv[i], result);
            }
            continue;
        }

        result = SecCodeCopySigningInformation(staticCode, kSecCSDefaultFlags, (CFDictionaryRef*)&info);
        CFRelease(staticCode);
        if (result != errSecSuccess) {
            fprintf(stderr, "Unable to copy cdhash info for %s\n", argv[i]);
            continue;
        }
        NSArray *cdhashes = info[@"cdhashes"];
        NSArray *algos = info[@"digest-algorithms"];
        NSUInteger algoIndex = [algos indexOfObject:@(cdHashTypeSHA256)];

        if (cdhashes == nil) {
            printf("%s: no cdhashes\n", argv[i]);
        } else if (algos == nil) {
            printf("%s: no algos\n", argv[i]);
        } else if (algoIndex == NSNotFound) {
            printf("%s: does not have SHA256 hash\n", argv[i]);
        } else {
            NSData *cdhash = [cdhashes objectAtIndex:algoIndex];
            if (cdhash != nil) {
                printf("%s: OK\n", argv[i]);
                hashes[cdhash] = @(argv[i]);
            } else {
                printf("%s: missing SHA256 cdhash entry\n", argv[i]);
            }
        }
        [info release];
    }
    int numHashes = [hashes count];

    if (numHashes < 1) {
        fprintf(stderr, "Found no hashes to inject\n");
        [hashes release];
        return 0;
    }


    NSArray *filtered = filteredHashes(mem.next, hashes, amficache);
    int hashesToInject = [filtered count];
    printf("%d new hashes to inject\n", hashesToInject);
    if (hashesToInject < 1) {
        return numHashes;
    }

    size_t length = (sizeof(mem) + hashesToInject * TRUST_CDHASH_LEN + 0xFFFF) & ~0xFFFF;
    char *buffer = malloc(hashesToInject * TRUST_CDHASH_LEN);
    if (buffer == NULL) {
        fprintf(stderr, "Unable to allocate memory for cdhashes: %s\n", strerror(errno));
        return -3;
    }
    char *curbuf = buffer;
    for (NSData *hash in filtered) {
        memcpy(curbuf, [hash bytes], TRUST_CDHASH_LEN);
        curbuf += TRUST_CDHASH_LEN;
    }
    kernel_trust = kmem_alloc(length);

    mem.count = hashesToInject;
    kwrite(kernel_trust, &mem, sizeof(mem));
    kwrite(kernel_trust + sizeof(mem), buffer, mem.count * TRUST_CDHASH_LEN);
    wk64(trust_chain, kernel_trust);

    return numHashes;
  }
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        fprintf(stderr,"Usage: inject /full/path/to/executable\n");
        fprintf(stderr,"Inject executables to trust cache\n");
        return -1;
    }
    void *lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    if (lib != NULL) {
        _SecCopyErrorMessageString = dlsym(lib, "SecCopyErrorMessageString");
        dlclose(lib);
    }
    tfp0 = try_restore_port();
    if (tfp0 == MACH_PORT_NULL)
        return -2;
    uint64_t kernel_base = get_kernel_base(tfp0);
    init_kernel(kernel_base, NULL);
    uint64_t trust_chain = find_trustcache();
    uint64_t amficache = find_amficache();
    term_kernel();
    bzero(amfiIndex, sizeof(amfiIndex));
    printf("Injecting to trust cache...\n");
    int ninjected = injectTrustCache(argc, argv, trust_chain, amficache);
    printf("Successfully injected [%d/%d] to trust cache.\n", ninjected, argc - 1);
    return argc - ninjected - 1;
}
