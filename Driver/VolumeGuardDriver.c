//
//  VolumeGuardDriver.c
//  VolumeGuard Virtual Audio HAL Driver
//
//  A lightweight, self-contained macOS CoreAudio AudioServerPlugIn loop-back driver
//  that exposes native master volume & mute controls and a 2-channel 32-bit float
//  ring buffer so VolumeGuard.app can route and control volume on HDMI, DisplayPort,
//  USB, and Bluetooth outputs.
//
//  License: MIT
//

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <math.h>
#include <string.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// MARK: - Constants & Object IDs

#define kPlugIn_BundleID            "dev.volumeguard.driver"
#define kDevice_UID                 "VolumeGuard_VirtualDevice"
#define kDevice_ModelUID            "VolumeGuard_Model_v1"
#define kDevice_DefaultName         "VolumeGuard Audio"
#define kDevice_Manufacturer        "VolumeGuard"

enum {
    kObjectID_PlugIn                    = kAudioObjectPlugInObject,
    kObjectID_Device                    = 2,
    kObjectID_Stream_Input              = 3,
    kObjectID_Stream_Output             = 4,
    kObjectID_Volume_Output_Master      = 5,
    kObjectID_Mute_Output_Master        = 6
};

enum {
    kCustomProperty_DeviceName          = 'vgnm', // CFString
    kCustomProperty_DeviceShown         = 'vgsh', // CFBoolean
    kCustomProperty_DeviceLatency       = 'vglt', // CFNumber (sInt32Type)
    kCustomProperty_DriverVersion       = 'vgvr'  // CFString
};

#define kChannelCount               2
#define kBitsPerChannel             32
#define kBytesPerChannel            4
#define kBytesPerFrame              (kChannelCount * kBytesPerChannel)
#define kRingBufferFrames           65536
#define kZeroTimeStampPeriod        4096
#define kMinVolumeDB                (-96.0f)
#define kMaxVolumeDB                0.0f

#define kVolumeGuardShmName         "/vg_audio_shm_v1"
#define kShmMagic                   0x56475348U

typedef struct {
    uint32_t magic;
    uint32_t channels;
    uint32_t capacityFrames;
    _Atomic uint32_t isRunning;
    _Atomic uint64_t writeFrameCounter;
    _Atomic uint64_t lastWriteHostTime;
    float samples[kRingBufferFrames * kChannelCount];
} VolumeGuardSharedAudio;

static const Float64 kSupportedSampleRates[] = {
    44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0
};
static const UInt32 kSupportedSampleRatesCount = sizeof(kSupportedSampleRates) / sizeof(kSupportedSampleRates[0]);

static const AudioServerPlugInCustomPropertyInfo kDeviceCustomProperties[] = {
    { kCustomProperty_DeviceName,    kAudioServerPlugInCustomPropertyDataTypeCFString,       kAudioServerPlugInCustomPropertyDataTypeNone },
    { kCustomProperty_DeviceShown,   kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
    { kCustomProperty_DeviceLatency, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
    { kCustomProperty_DriverVersion, kAudioServerPlugInCustomPropertyDataTypeCFString,       kAudioServerPlugInCustomPropertyDataTypeNone }
};
static const UInt32 kDeviceCustomPropertiesCount = sizeof(kDeviceCustomProperties) / sizeof(kDeviceCustomProperties[0]);

// MARK: - Driver State

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gIOMutex    = PTHREAD_MUTEX_INITIALIZER;

static AudioServerPlugInHostRef gPlugInHost = NULL;
static _Atomic UInt32 gRefCount = 0;
static _Atomic UInt32 gIOClientCount = 0;

static CFStringRef gDeviceName = NULL;
static Boolean gDeviceShown = true;
static UInt32 gDeviceLatency = 0;
static Float64 gSampleRate = 48000.0;

static Float32 gOutputVolumeScalar = 1.0f;
static UInt32 gOutputMute = 0;

static Boolean gInputStreamActive = true;
static Boolean gOutputStreamActive = true;

static Float32 gRingBuffer[kRingBufferFrames * kChannelCount];
static VolumeGuardSharedAudio *gSharedAudio = NULL;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimestampSeed = 1;
static Float64 gHostTicksPerFrame = 0.0;
static UInt64 gNumberTimeStamps = 0;

// MARK: - Helpers

static void EnsureSharedMemory(void) {
    if (gSharedAudio != NULL) return;
    mode_t oldMask = umask(0);
    int fd = shm_open(kVolumeGuardShmName, O_CREAT | O_RDWR, 0666);
    umask(oldMask);
    if (fd < 0) return;
    fchmod(fd, 0666);
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size < (off_t)sizeof(VolumeGuardSharedAudio)) {
        ftruncate(fd, (off_t)sizeof(VolumeGuardSharedAudio));
    }
    if (fstat(fd, &st) == 0 && st.st_size >= (off_t)sizeof(VolumeGuardSharedAudio)) {
        void *ptr = mmap(NULL, sizeof(VolumeGuardSharedAudio), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (ptr != MAP_FAILED && ptr != NULL) {
            VolumeGuardSharedAudio *shm = (VolumeGuardSharedAudio *)ptr;
            memset(shm->samples, 0, sizeof(shm->samples));
            atomic_store_explicit(&shm->writeFrameCounter, 0, memory_order_relaxed);
            atomic_store_explicit(&shm->lastWriteHostTime, 0, memory_order_relaxed);
            atomic_store_explicit(&shm->isRunning, 0, memory_order_relaxed);
            shm->channels = kChannelCount;
            shm->capacityFrames = kRingBufferFrames;
            shm->magic = kShmMagic;
            gSharedAudio = shm;
        }
    }
    close(fd);
}

static void UpdateHostTicksPerFrame(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    Float64 clockFreq = ((Float64)info.denom / (Float64)info.numer) * 1000000000.0;
    gHostTicksPerFrame = clockFreq / gSampleRate;
}

static Float32 ScalarToDecibels(Float32 scalar) {
    if (scalar <= 0.0f) return kMinVolumeDB;
    if (scalar >= 1.0f) return kMaxVolumeDB;
    // Perceptual cubic mapping between -96 dB and 0 dB
    Float32 db = 20.0f * log10f(scalar * scalar);
    if (db < kMinVolumeDB) db = kMinVolumeDB;
    if (db > kMaxVolumeDB) db = kMaxVolumeDB;
    return db;
}

static Float32 DecibelsToScalar(Float32 db) {
    if (db <= kMinVolumeDB) return 0.0f;
    if (db >= kMaxVolumeDB) return 1.0f;
    Float32 s = powf(10.0f, db / 40.0f);
    if (s < 0.0f) s = 0.0f;
    if (s > 1.0f) s = 1.0f;
    return s;
}

static AudioStreamBasicDescription MakeStreamFormat(Float64 sampleRate) {
    AudioStreamBasicDescription desc;
    memset(&desc, 0, sizeof(desc));
    desc.mSampleRate       = sampleRate;
    desc.mFormatID         = kAudioFormatLinearPCM;
    desc.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    desc.mBytesPerPacket   = kBytesPerFrame;
    desc.mFramesPerPacket  = 1;
    desc.mBytesPerFrame    = kBytesPerFrame;
    desc.mChannelsPerFrame = kChannelCount;
    desc.mBitsPerChannel   = kBitsPerChannel;
    return desc;
}

static void NotifyPropertiesChanged(AudioObjectID objectID, UInt32 count, const AudioObjectPropertyAddress addresses[]) {
    if (gPlugInHost != NULL && gPlugInHost->PropertiesChanged != NULL) {
        gPlugInHost->PropertiesChanged(gPlugInHost, objectID, count, addresses);
    }
}

// MARK: - IUnknown

static HRESULT VolumeGuard_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG   VolumeGuard_AddRef(void *inDriver);
static ULONG   VolumeGuard_Release(void *inDriver);

// MARK: - Basic Operations

static OSStatus VolumeGuard_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    pthread_mutex_lock(&gStateMutex);
    gPlugInHost = inHost;
    if (gDeviceName == NULL) {
        gDeviceName = CFStringCreateWithCString(kCFAllocatorDefault, kDevice_DefaultName, kCFStringEncodingUTF8);
    }
    UpdateHostTicksPerFrame();
    memset(gRingBuffer, 0, sizeof(gRingBuffer));
    EnsureSharedMemory();
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus VolumeGuard_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus VolumeGuard_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus VolumeGuard_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus VolumeGuard_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus VolumeGuard_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    pthread_mutex_lock(&gIOMutex);
    if (inChangeInfo != NULL) {
        UInt64 rateBits = (uintptr_t)inChangeInfo;
        Float64 newRate = (Float64)rateBits;
        if (newRate >= 44100.0 && newRate <= 192000.0) {
            gSampleRate = newRate;
            UpdateHostTicksPerFrame();
            gNumberTimeStamps = 0;
            gAnchorHostTime = mach_absolute_time();
            gTimestampSeed += 1;
            memset(gRingBuffer, 0, sizeof(gRingBuffer));
            if (gSharedAudio != NULL) {
                memset(gSharedAudio->samples, 0, sizeof(gSharedAudio->samples));
            }
        }
    }
    pthread_mutex_unlock(&gIOMutex);
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus VolumeGuard_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    return kAudioHardwareNoError;
}

// MARK: - Property Operations

static Boolean VolumeGuard_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    if (inAddress == NULL) return false;
    AudioObjectPropertySelector sel = inAddress->mSelector;
    AudioObjectPropertyScope scope  = inAddress->mScope;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                case kAudioPlugInPropertyResourceBundle:
                    return true;
                default:
                    return false;
            }

        case kObjectID_Device:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioObjectPropertyControlList:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyStreams:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioObjectPropertyCustomPropertyInfoList:
                case kCustomProperty_DeviceName:
                case kCustomProperty_DeviceShown:
                case kCustomProperty_DeviceLatency:
                case kCustomProperty_DriverVersion:
                    return true;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kAudioDevicePropertyPreferredChannelLayout:
                    return (scope == kAudioObjectPropertyScopeInput || scope == kAudioObjectPropertyScopeOutput);
                default:
                    return false;
            }

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return true;
                default:
                    return false;
            }

        case kObjectID_Volume_Output_Master:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyDecibelRange:
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    return true;
                default:
                    return false;
            }

        case kObjectID_Mute_Output_Master:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioBooleanControlPropertyValue:
                    return true;
                default:
                    return false;
            }

        default:
            return false;
    }
}

static OSStatus VolumeGuard_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!VolumeGuard_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    *outIsSettable = false;
    AudioObjectPropertySelector sel = inAddress->mSelector;

    switch (inObjectID) {
        case kObjectID_Device:
            if (sel == kAudioDevicePropertyNominalSampleRate ||
                sel == kAudioObjectPropertyName ||
                sel == kCustomProperty_DeviceName ||
                sel == kCustomProperty_DeviceShown ||
                sel == kCustomProperty_DeviceLatency) {
                *outIsSettable = true;
            }
            break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            if (sel == kAudioStreamPropertyIsActive ||
                sel == kAudioStreamPropertyVirtualFormat ||
                sel == kAudioStreamPropertyPhysicalFormat) {
                *outIsSettable = true;
            }
            break;
        case kObjectID_Volume_Output_Master:
            if (sel == kAudioLevelControlPropertyScalarValue ||
                sel == kAudioLevelControlPropertyDecibelValue) {
                *outIsSettable = true;
            }
            break;
        case kObjectID_Mute_Output_Master:
            if (sel == kAudioBooleanControlPropertyValue) {
                *outIsSettable = true;
            }
            break;
    }
    return kAudioHardwareNoError;
}

static OSStatus VolumeGuard_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    if (!VolumeGuard_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    AudioObjectPropertySelector sel = inAddress->mSelector;
    AudioObjectPropertyScope scope  = inAddress->mScope;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass: *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                case kAudioPlugInPropertyResourceBundle: *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList: *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            }
            break;

        case kObjectID_Device:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass: *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner: *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kCustomProperty_DeviceName:
                case kCustomProperty_DriverVersion: *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
                case kCustomProperty_DeviceShown: *outDataSize = sizeof(CFBooleanRef); return kAudioHardwareNoError;
                case kCustomProperty_DeviceLatency: *outDataSize = sizeof(CFNumberRef); return kAudioHardwareNoError;
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = kDeviceCustomPropertiesCount * sizeof(AudioServerPlugInCustomPropertyInfo);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    if (scope == kAudioObjectPropertyScopeInput) {
                        *outDataSize = 1 * sizeof(AudioObjectID);
                    } else if (scope == kAudioObjectPropertyScopeOutput) {
                        *outDataSize = 3 * sizeof(AudioObjectID);
                    } else {
                        *outDataSize = 4 * sizeof(AudioObjectID);
                    }
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreams:
                    if (scope == kAudioObjectPropertyScopeInput || scope == kAudioObjectPropertyScopeOutput) {
                        *outDataSize = 1 * sizeof(AudioObjectID);
                    } else {
                        *outDataSize = 2 * sizeof(AudioObjectID);
                    }
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyControlList:
                    *outDataSize = 2 * sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyRelatedDevices:
                    *outDataSize = 1 * sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyNominalSampleRate:
                    *outDataSize = sizeof(Float64);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    *outDataSize = kSupportedSampleRatesCount * sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    *outDataSize = 2 * sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyPreferredChannelLayout:
                    *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelCount * sizeof(AudioChannelDescription));
                    return kAudioHardwareNoError;
            }
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass: *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner: *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return kAudioHardwareNoError;
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency: *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: *outDataSize = sizeof(AudioStreamBasicDescription); return kAudioHardwareNoError;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *outDataSize = kSupportedSampleRatesCount * sizeof(AudioStreamRangedDescription);
                    return kAudioHardwareNoError;
            }
            break;

        case kObjectID_Volume_Output_Master:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass: *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner: *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return kAudioHardwareNoError;
                case kAudioControlPropertyScope: *outDataSize = sizeof(AudioObjectPropertyScope); return kAudioHardwareNoError;
                case kAudioControlPropertyElement: *outDataSize = sizeof(AudioObjectPropertyElement); return kAudioHardwareNoError;
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar: *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
                case kAudioLevelControlPropertyDecibelRange: *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
            }
            break;

        case kObjectID_Mute_Output_Master:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass: *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner: *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return kAudioHardwareNoError;
                case kAudioControlPropertyScope: *outDataSize = sizeof(AudioObjectPropertyScope); return kAudioHardwareNoError;
                case kAudioControlPropertyElement: *outDataSize = sizeof(AudioObjectPropertyElement); return kAudioHardwareNoError;
                case kAudioBooleanControlPropertyValue: *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            }
            break;
    }

    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VolumeGuard_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    if (!VolumeGuard_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    AudioObjectPropertySelector sel = inAddress->mSelector;
    AudioObjectPropertyScope scope  = inAddress->mScope;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioPlugInClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectID *)outData) = kAudioObjectUnknown;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = CFSTR(kDevice_Manufacturer);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    if (inDataSize < sizeof(AudioObjectID)) {
                        *outDataSize = 0;
                        return kAudioHardwareNoError;
                    }
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    if (inDataSize < sizeof(AudioObjectID) || inQualifierData == NULL || inQualifierDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    CFStringRef uid = *((const CFStringRef *)inQualifierData);
                    if (uid != NULL && CFStringCompare(uid, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo) {
                        *((AudioObjectID *)outData) = kObjectID_Device;
                    } else {
                        *((AudioObjectID *)outData) = kAudioObjectUnknown;
                    }
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                }
                case kAudioPlugInPropertyResourceBundle:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = CFSTR("");
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
            }
            break;

        case kObjectID_Device:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioDeviceClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectID *)outData) = kObjectID_PlugIn;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                case kCustomProperty_DeviceName:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    pthread_mutex_lock(&gStateMutex);
                    if (gDeviceName == NULL) {
                        gDeviceName = CFStringCreateWithCString(kCFAllocatorDefault, kDevice_DefaultName, kCFStringEncodingUTF8);
                    }
                    CFRetain(gDeviceName);
                    *((CFStringRef *)outData) = gDeviceName;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyManufacturer:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = CFSTR(kDevice_Manufacturer);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceUID:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = CFSTR(kDevice_UID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyModelUID:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    *((CFStringRef *)outData) = CFSTR(kDevice_ModelUID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kCustomProperty_DriverVersion:
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    EnsureSharedMemory();
                    *((CFStringRef *)outData) = CFSTR("1.2.0");
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kCustomProperty_DeviceShown:
                    if (inDataSize < sizeof(CFBooleanRef)) return kAudioHardwareBadPropertySizeError;
                    pthread_mutex_lock(&gStateMutex);
                    *((CFBooleanRef *)outData) = gDeviceShown ? kCFBooleanTrue : kCFBooleanFalse;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(CFBooleanRef);
                    return kAudioHardwareNoError;
                case kCustomProperty_DeviceLatency: {
                    if (inDataSize < sizeof(CFNumberRef)) return kAudioHardwareBadPropertySizeError;
                    pthread_mutex_lock(&gStateMutex);
                    SInt32 lat = (SInt32)gDeviceLatency;
                    pthread_mutex_unlock(&gStateMutex);
                    *((CFNumberRef *)outData) = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &lat);
                    *outDataSize = sizeof(CFNumberRef);
                    return kAudioHardwareNoError;
                }
                case kAudioObjectPropertyCustomPropertyInfoList: {
                    UInt32 count = inDataSize / sizeof(AudioServerPlugInCustomPropertyInfo);
                    if (count > kDeviceCustomPropertiesCount) count = kDeviceCustomPropertiesCount;
                    memcpy(outData, kDeviceCustomProperties, count * sizeof(AudioServerPlugInCustomPropertyInfo));
                    *outDataSize = count * sizeof(AudioServerPlugInCustomPropertyInfo);
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertyTransportType:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = kAudioDeviceTransportTypeVirtual;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyRelatedDevices:
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyClockDomain:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceIsAlive:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceIsRunning:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = (atomic_load(&gIOClientCount) > 0) ? 1 : 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyIsHidden:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    pthread_mutex_lock(&gStateMutex);
                    *((UInt32 *)outData) = gDeviceShown ? 1 : 0;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyLatency:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    pthread_mutex_lock(&gStateMutex);
                    *((UInt32 *)outData) = gDeviceLatency;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertySafetyOffset:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = kZeroTimeStampPeriod;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyNominalSampleRate:
                    if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                    pthread_mutex_lock(&gStateMutex);
                    *((Float64 *)outData) = gSampleRate;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(Float64);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    UInt32 count = inDataSize / sizeof(AudioValueRange);
                    if (count > kSupportedSampleRatesCount) count = kSupportedSampleRatesCount;
                    AudioValueRange *ranges = (AudioValueRange *)outData;
                    for (UInt32 i = 0; i < count; ++i) {
                        ranges[i].mMinimum = kSupportedSampleRates[i];
                        ranges[i].mMaximum = kSupportedSampleRates[i];
                    }
                    *outDataSize = count * sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertyStreams: {
                    AudioObjectID *ids = (AudioObjectID *)outData;
                    if (scope == kAudioObjectPropertyScopeInput) {
                        if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return kAudioHardwareNoError; }
                        ids[0] = kObjectID_Stream_Input;
                        *outDataSize = sizeof(AudioObjectID);
                    } else if (scope == kAudioObjectPropertyScopeOutput) {
                        if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return kAudioHardwareNoError; }
                        ids[0] = kObjectID_Stream_Output;
                        *outDataSize = sizeof(AudioObjectID);
                    } else {
                        UInt32 cap = inDataSize / sizeof(AudioObjectID);
                        if (cap >= 1) ids[0] = kObjectID_Stream_Input;
                        if (cap >= 2) ids[1] = kObjectID_Stream_Output;
                        *outDataSize = (cap > 2 ? 2 : cap) * sizeof(AudioObjectID);
                    }
                    return kAudioHardwareNoError;
                }
                case kAudioObjectPropertyControlList: {
                    AudioObjectID *ids = (AudioObjectID *)outData;
                    UInt32 cap = inDataSize / sizeof(AudioObjectID);
                    if (cap >= 1) ids[0] = kObjectID_Volume_Output_Master;
                    if (cap >= 2) ids[1] = kObjectID_Mute_Output_Master;
                    *outDataSize = (cap > 2 ? 2 : cap) * sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                }
                case kAudioObjectPropertyOwnedObjects: {
                    AudioObjectID *ids = (AudioObjectID *)outData;
                    UInt32 cap = inDataSize / sizeof(AudioObjectID);
                    if (scope == kAudioObjectPropertyScopeInput) {
                        if (cap >= 1) ids[0] = kObjectID_Stream_Input;
                        *outDataSize = (cap > 1 ? 1 : cap) * sizeof(AudioObjectID);
                    } else if (scope == kAudioObjectPropertyScopeOutput) {
                        const AudioObjectID list[3] = { kObjectID_Stream_Output, kObjectID_Volume_Output_Master, kObjectID_Mute_Output_Master };
                        UInt32 n = cap > 3 ? 3 : cap;
                        for (UInt32 i = 0; i < n; ++i) ids[i] = list[i];
                        *outDataSize = n * sizeof(AudioObjectID);
                    } else {
                        const AudioObjectID list[4] = { kObjectID_Stream_Input, kObjectID_Stream_Output, kObjectID_Volume_Output_Master, kObjectID_Mute_Output_Master };
                        UInt32 n = cap > 4 ? 4 : cap;
                        for (UInt32 i = 0; i < n; ++i) ids[i] = list[i];
                        *outDataSize = n * sizeof(AudioObjectID);
                    }
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertyPreferredChannelsForStereo: {
                    if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    UInt32 *ch = (UInt32 *)outData;
                    ch[0] = 1;
                    ch[1] = 2;
                    *outDataSize = 2 * sizeof(UInt32);
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertyPreferredChannelLayout: {
                    UInt32 reqSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelCount * sizeof(AudioChannelDescription)));
                    if (inDataSize < reqSize) return kAudioHardwareBadPropertySizeError;
                    AudioChannelLayout *layout = (AudioChannelLayout *)outData;
                    memset(layout, 0, reqSize);
                    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                    layout->mNumberChannelDescriptions = kChannelCount;
                    layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                    layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                    *outDataSize = reqSize;
                    return kAudioHardwareNoError;
                }
            }
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioStreamClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyIsActive:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    pthread_mutex_lock(&gStateMutex);
                    *((UInt32 *)outData) = (inObjectID == kObjectID_Stream_Input ? gInputStreamActive : gOutputStreamActive) ? 1 : 0;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyDirection:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = (inObjectID == kObjectID_Stream_Input) ? 1 : 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyTerminalType:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = (inObjectID == kObjectID_Stream_Input) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyStartingChannel:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyLatency:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    *((UInt32 *)outData) = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                    pthread_mutex_lock(&gStateMutex);
                    *((AudioStreamBasicDescription *)outData) = MakeStreamFormat(gSampleRate);
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    UInt32 count = inDataSize / sizeof(AudioStreamRangedDescription);
                    if (count > kSupportedSampleRatesCount) count = kSupportedSampleRatesCount;
                    AudioStreamRangedDescription *descs = (AudioStreamRangedDescription *)outData;
                    for (UInt32 i = 0; i < count; ++i) {
                        descs[i].mFormat = MakeStreamFormat(kSupportedSampleRates[i]);
                        descs[i].mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                        descs[i].mSampleRateRange.mMaximum = kSupportedSampleRates[i];
                    }
                    *outDataSize = count * sizeof(AudioStreamRangedDescription);
                    return kAudioHardwareNoError;
                }
            }
            break;

        case kObjectID_Volume_Output_Master:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioLevelControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioVolumeControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioControlPropertyScope:
                    if (inDataSize < sizeof(AudioObjectPropertyScope)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectPropertyScope *)outData) = kAudioObjectPropertyScopeOutput;
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    return kAudioHardwareNoError;
                case kAudioControlPropertyElement:
                    if (inDataSize < sizeof(AudioObjectPropertyElement)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectPropertyElement *)outData) = kAudioObjectPropertyElementMain;
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    return kAudioHardwareNoError;
                case kAudioLevelControlPropertyScalarValue:
                    if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                    pthread_mutex_lock(&gStateMutex);
                    *((Float32 *)outData) = gOutputVolumeScalar;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(Float32);
                    return kAudioHardwareNoError;
                case kAudioLevelControlPropertyDecibelValue:
                    if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                    pthread_mutex_lock(&gStateMutex);
                    *((Float32 *)outData) = ScalarToDecibels(gOutputVolumeScalar);
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(Float32);
                    return kAudioHardwareNoError;
                case kAudioLevelControlPropertyDecibelRange: {
                    if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
                    AudioValueRange *range = (AudioValueRange *)outData;
                    range->mMinimum = kMinVolumeDB;
                    range->mMaximum = kMaxVolumeDB;
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                }
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                    if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                    *((Float32 *)outData) = ScalarToDecibels(*((Float32 *)outData));
                    *outDataSize = sizeof(Float32);
                    return kAudioHardwareNoError;
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                    *((Float32 *)outData) = DecibelsToScalar(*((Float32 *)outData));
                    *outDataSize = sizeof(Float32);
                    return kAudioHardwareNoError;
            }
            break;

        case kObjectID_Mute_Output_Master:
            switch (sel) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioBooleanControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioClassID *)outData) = kAudioMuteControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioControlPropertyScope:
                    if (inDataSize < sizeof(AudioObjectPropertyScope)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectPropertyScope *)outData) = kAudioObjectPropertyScopeOutput;
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    return kAudioHardwareNoError;
                case kAudioControlPropertyElement:
                    if (inDataSize < sizeof(AudioObjectPropertyElement)) return kAudioHardwareBadPropertySizeError;
                    *((AudioObjectPropertyElement *)outData) = kAudioObjectPropertyElementMain;
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    return kAudioHardwareNoError;
                case kAudioBooleanControlPropertyValue:
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    pthread_mutex_lock(&gStateMutex);
                    *((UInt32 *)outData) = gOutputMute;
                    pthread_mutex_unlock(&gStateMutex);
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
            }
            break;
    }

    return kAudioHardwareUnknownPropertyError;
}

static OSStatus VolumeGuard_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    if (!VolumeGuard_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    AudioObjectPropertySelector sel = inAddress->mSelector;

    switch (inObjectID) {
        case kObjectID_Device:
            switch (sel) {
                case kAudioDevicePropertyNominalSampleRate: {
                    if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                    Float64 newRate = *((const Float64 *)inData);
                    Boolean valid = false;
                    for (UInt32 i = 0; i < kSupportedSampleRatesCount; ++i) {
                        if (fabs(kSupportedSampleRates[i] - newRate) < 0.5) {
                            newRate = kSupportedSampleRates[i];
                            valid = true;
                            break;
                        }
                    }
                    if (!valid) return kAudioDeviceUnsupportedFormatError;
                    if (gPlugInHost != NULL && gPlugInHost->RequestDeviceConfigurationChange != NULL) {
                        gPlugInHost->RequestDeviceConfigurationChange(gPlugInHost, kObjectID_Device, 0, (void *)(uintptr_t)newRate);
                    } else {
                        pthread_mutex_lock(&gStateMutex);
                        gSampleRate = newRate;
                        UpdateHostTicksPerFrame();
                        pthread_mutex_unlock(&gStateMutex);
                    }
                    AudioObjectPropertyAddress changed[1] = {
                        { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
                    };
                    NotifyPropertiesChanged(kObjectID_Device, 1, changed);
                    return kAudioHardwareNoError;
                }
                case kAudioObjectPropertyName:
                case kCustomProperty_DeviceName: {
                    if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                    CFStringRef newName = *((const CFStringRef *)inData);
                    if (newName == NULL) return kAudioHardwareIllegalOperationError;
                    pthread_mutex_lock(&gStateMutex);
                    CFRetain(newName);
                    if (gDeviceName != NULL) CFRelease(gDeviceName);
                    gDeviceName = newName;
                    pthread_mutex_unlock(&gStateMutex);
                    AudioObjectPropertyAddress changed[2] = {
                        { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                        { kCustomProperty_DeviceName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
                    };
                    NotifyPropertiesChanged(kObjectID_Device, 2, changed);
                    return kAudioHardwareNoError;
                }
                case kCustomProperty_DeviceShown: {
                    if (inDataSize < sizeof(CFBooleanRef)) return kAudioHardwareBadPropertySizeError;
                    CFBooleanRef val = *((const CFBooleanRef *)inData);
                    pthread_mutex_lock(&gStateMutex);
                    gDeviceShown = (val == kCFBooleanTrue);
                    pthread_mutex_unlock(&gStateMutex);
                    AudioObjectPropertyAddress changed[3] = {
                        { kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                        { kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
                        { kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
                    };
                    NotifyPropertiesChanged(kObjectID_Device, 3, changed);
                    return kAudioHardwareNoError;
                }
                case kCustomProperty_DeviceLatency: {
                    if (inDataSize < sizeof(CFNumberRef)) return kAudioHardwareBadPropertySizeError;
                    CFNumberRef num = *((const CFNumberRef *)inData);
                    SInt32 lat = 0;
                    if (num != NULL && CFNumberGetValue(num, kCFNumberSInt32Type, &lat)) {
                        pthread_mutex_lock(&gStateMutex);
                        gDeviceLatency = (lat >= 0) ? (UInt32)lat : 0;
                        pthread_mutex_unlock(&gStateMutex);
                        AudioObjectPropertyAddress changed[1] = {
                            { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain }
                        };
                        NotifyPropertiesChanged(kObjectID_Device, 1, changed);
                    }
                    return kAudioHardwareNoError;
                }
            }
            break;

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (sel) {
                case kAudioStreamPropertyIsActive: {
                    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                    Boolean active = (*((const UInt32 *)inData) != 0);
                    pthread_mutex_lock(&gStateMutex);
                    if (inObjectID == kObjectID_Stream_Input) gInputStreamActive = active;
                    else gOutputStreamActive = active;
                    pthread_mutex_unlock(&gStateMutex);
                    AudioObjectPropertyAddress changed[1] = {
                        { kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
                    };
                    NotifyPropertiesChanged(inObjectID, 1, changed);
                    return kAudioHardwareNoError;
                }
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                    const AudioStreamBasicDescription *desc = (const AudioStreamBasicDescription *)inData;
                    Float64 newRate = desc->mSampleRate;
                    Boolean valid = false;
                    for (UInt32 i = 0; i < kSupportedSampleRatesCount; ++i) {
                        if (fabs(kSupportedSampleRates[i] - newRate) < 0.5) {
                            newRate = kSupportedSampleRates[i];
                            valid = true;
                            break;
                        }
                    }
                    if (!valid) return kAudioDeviceUnsupportedFormatError;
                    if (gPlugInHost != NULL && gPlugInHost->RequestDeviceConfigurationChange != NULL) {
                        gPlugInHost->RequestDeviceConfigurationChange(gPlugInHost, kObjectID_Device, 0, (void *)(uintptr_t)newRate);
                    }
                    return kAudioHardwareNoError;
                }
            }
            break;

        case kObjectID_Volume_Output_Master:
            switch (sel) {
                case kAudioLevelControlPropertyScalarValue: {
                    if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                    Float32 val = *((const Float32 *)inData);
                    if (val < 0.0f) val = 0.0f;
                    if (val > 1.0f) val = 1.0f;
                    pthread_mutex_lock(&gStateMutex);
                    gOutputVolumeScalar = val;
                    pthread_mutex_unlock(&gStateMutex);
                    AudioObjectPropertyAddress changed[2] = {
                        { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                        { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
                    };
                    NotifyPropertiesChanged(kObjectID_Volume_Output_Master, 2, changed);
                    return kAudioHardwareNoError;
                }
                case kAudioLevelControlPropertyDecibelValue: {
                    if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                    Float32 db = *((const Float32 *)inData);
                    Float32 val = DecibelsToScalar(db);
                    pthread_mutex_lock(&gStateMutex);
                    gOutputVolumeScalar = val;
                    pthread_mutex_unlock(&gStateMutex);
                    AudioObjectPropertyAddress changed[2] = {
                        { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                        { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
                    };
                    NotifyPropertiesChanged(kObjectID_Volume_Output_Master, 2, changed);
                    return kAudioHardwareNoError;
                }
            }
            break;

        case kObjectID_Mute_Output_Master:
            if (sel == kAudioBooleanControlPropertyValue) {
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                UInt32 val = (*((const UInt32 *)inData) != 0) ? 1 : 0;
                pthread_mutex_lock(&gStateMutex);
                gOutputMute = val;
                pthread_mutex_unlock(&gStateMutex);
                AudioObjectPropertyAddress changed[1] = {
                    { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
                };
                NotifyPropertiesChanged(kObjectID_Mute_Output_Master, 1, changed);
                return kAudioHardwareNoError;
            }
            break;
    }

    return kAudioHardwareUnknownPropertyError;
}

// MARK: - IO Operations

static OSStatus VolumeGuard_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gIOMutex);
    EnsureSharedMemory();
    UInt32 prev = atomic_fetch_add(&gIOClientCount, 1);
    if (prev == 0) {
        memset(gRingBuffer, 0, sizeof(gRingBuffer));
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        gTimestampSeed += 1;
        if (gSharedAudio != NULL) {
            memset(gSharedAudio->samples, 0, sizeof(gSharedAudio->samples));
            atomic_store_explicit(&gSharedAudio->isRunning, 1, memory_order_release);
        }
    }
    pthread_mutex_unlock(&gIOMutex);

    AudioObjectPropertyAddress changed[1] = {
        { kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
    };
    NotifyPropertiesChanged(kObjectID_Device, 1, changed);
    return kAudioHardwareNoError;
}

static OSStatus VolumeGuard_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gIOMutex);
    UInt32 cur = atomic_load(&gIOClientCount);
    if (cur > 0) {
        cur = atomic_fetch_sub(&gIOClientCount, 1) - 1;
    }
    if (cur == 0) {
        memset(gRingBuffer, 0, sizeof(gRingBuffer));
        if (gSharedAudio != NULL) {
            atomic_store_explicit(&gSharedAudio->isRunning, 0, memory_order_release);
            memset(gSharedAudio->samples, 0, sizeof(gSharedAudio->samples));
        }
    }
    pthread_mutex_unlock(&gIOMutex);

    AudioObjectPropertyAddress changed[1] = {
        { kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
    };
    NotifyPropertiesChanged(kObjectID_Device, 1, changed);
    return kAudioHardwareNoError;
}

static OSStatus VolumeGuard_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gIOMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    if (ticksPerPeriod > 0.0) {
        UInt64 elapsedTicks = (now > gAnchorHostTime) ? (now - gAnchorHostTime) : 0;
        UInt64 periods = (UInt64)((Float64)elapsedTicks / ticksPerPeriod);
        gNumberTimeStamps = periods;
    }
    if (outSampleTime != NULL) *outSampleTime = (Float64)(gNumberTimeStamps * kZeroTimeStampPeriod);
    if (outHostTime   != NULL) *outHostTime   = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps * kZeroTimeStampPeriod) * gHostTicksPerFrame);
    if (outSeed       != NULL) *outSeed       = gTimestampSeed;
    pthread_mutex_unlock(&gIOMutex);
    return kAudioHardwareNoError;
}

static OSStatus VolumeGuard_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean willDo = false;
    Boolean inPlace = true;
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationWriteMix:
        case kAudioServerPlugInIOOperationReadInput:
            willDo = true;
            inPlace = true;
            break;
        default:
            willDo = false;
            inPlace = true;
            break;
    }
    if (outWillDo != NULL) *outWillDo = willDo;
    if (outWillDoInPlace != NULL) *outWillDoInPlace = inPlace;
    return kAudioHardwareNoError;
}

static OSStatus VolumeGuard_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    return kAudioHardwareNoError;
}

static OSStatus VolumeGuard_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    if (inDeviceObjectID != kObjectID_Device || ioMainBuffer == NULL || inIOCycleInfo == NULL) {
        return kAudioHardwareNoError;
    }

    Float32 *buf = (Float32 *)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        if (gSharedAudio != NULL) {
            uint64_t writePos = atomic_load_explicit(&gSharedAudio->writeFrameCounter, memory_order_relaxed);
            for (UInt32 f = 0; f < inIOBufferFrameSize; ++f) {
                UInt32 sIdx = (UInt32)((writePos + f) % kRingBufferFrames) * kChannelCount;
                gSharedAudio->samples[sIdx]     = buf[f * kChannelCount];
                gSharedAudio->samples[sIdx + 1] = buf[f * kChannelCount + 1];
            }
            atomic_store_explicit(&gSharedAudio->lastWriteHostTime, mach_absolute_time(), memory_order_relaxed);
            atomic_store_explicit(&gSharedAudio->writeFrameCounter, writePos + inIOBufferFrameSize, memory_order_release);
            atomic_store_explicit(&gSharedAudio->isRunning, 1, memory_order_release);
        }
        UInt64 sampleTime = (UInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 f = 0; f < inIOBufferFrameSize; ++f) {
            UInt32 idx = (UInt32)((sampleTime + f) % kRingBufferFrames) * kChannelCount;
            gRingBuffer[idx]     = buf[f * kChannelCount];
            gRingBuffer[idx + 1] = buf[f * kChannelCount + 1];
        }
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        UInt64 sampleTime = (UInt64)inIOCycleInfo->mInputTime.mSampleTime;
        pthread_mutex_lock(&gIOMutex);
        for (UInt32 f = 0; f < inIOBufferFrameSize; ++f) {
            UInt32 idx = (UInt32)((sampleTime + f) % kRingBufferFrames) * kChannelCount;
            buf[f * kChannelCount]     = gRingBuffer[idx];
            buf[f * kChannelCount + 1] = gRingBuffer[idx + 1];
            // Clear after reading so silence is produced if output stops writing
            gRingBuffer[idx]     = 0.0f;
            gRingBuffer[idx + 1] = 0.0f;
        }
        pthread_mutex_unlock(&gIOMutex);
    }

    return kAudioHardwareNoError;
}

static OSStatus VolumeGuard_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    return kAudioHardwareNoError;
}

// MARK: - Interface Table & Factory

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    VolumeGuard_QueryInterface,
    VolumeGuard_AddRef,
    VolumeGuard_Release,
    VolumeGuard_Initialize,
    VolumeGuard_CreateDevice,
    VolumeGuard_DestroyDevice,
    VolumeGuard_AddDeviceClient,
    VolumeGuard_RemoveDeviceClient,
    VolumeGuard_PerformDeviceConfigurationChange,
    VolumeGuard_AbortDeviceConfigurationChange,
    VolumeGuard_HasProperty,
    VolumeGuard_IsPropertySettable,
    VolumeGuard_GetPropertyDataSize,
    VolumeGuard_GetPropertyData,
    VolumeGuard_SetPropertyData,
    VolumeGuard_StartIO,
    VolumeGuard_StopIO,
    VolumeGuard_GetZeroTimeStamp,
    VolumeGuard_WillDoIOOperation,
    VolumeGuard_BeginIOOperation,
    VolumeGuard_DoIOOperation,
    VolumeGuard_EndIOOperation
};

static AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;

static HRESULT VolumeGuard_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (outInterface == NULL) return E_POINTER;
    CFUUIDRef reqUUID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, inUUID);
    Boolean match = CFEqual(reqUUID, kAudioServerPlugInDriverInterfaceUUID) || CFEqual(reqUUID, IUnknownUUID);
    CFRelease(reqUUID);
    if (!match) {
        *outInterface = NULL;
        return E_NOINTERFACE;
    }
    atomic_fetch_add(&gRefCount, 1);
    *outInterface = &gDriverInterfacePtr;
    return S_OK;
}

static ULONG VolumeGuard_AddRef(void *inDriver) {
    return (ULONG)(atomic_fetch_add(&gRefCount, 1) + 1);
}

static ULONG VolumeGuard_Release(void *inDriver) {
    UInt32 prev = atomic_load(&gRefCount);
    if (prev > 0) {
        return (ULONG)(atomic_fetch_sub(&gRefCount, 1) - 1);
    }
    return 0;
}

__attribute__((visibility("default")))
void *VolumeGuardPlugIn_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    if (inRequestedTypeUUID == NULL || !CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    atomic_fetch_add(&gRefCount, 1);
    return &gDriverInterfacePtr;
}
