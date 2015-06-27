/*
   +----------------------------------------------------------------------+
   | HipHop for PHP                                                       |
   +----------------------------------------------------------------------+
   | Copyright (c) 2010-2014 Facebook, Inc. (http://www.facebook.com)     |
   +----------------------------------------------------------------------+
   | This source file is subject to version 3.01 of the PHP license,      |
   | that is bundled with this package in the file LICENSE, and is        |
   | available through the world-wide-web at the following url:           |
   | http://www.php.net/license/3_01.txt                                  |
   | If you did not receive a copy of the PHP license and are unable to   |
   | obtain it through the world-wide-web, please send a note to          |
   | license@php.net so we can mail you a copy immediately.               |
   +----------------------------------------------------------------------+
*/

#ifndef incl_HPHP_RUNTIME_VM_RESUMABLE_H_
#define incl_HPHP_RUNTIME_VM_RESUMABLE_H_

#include "hphp/runtime/vm/bytecode.h"
#include "hphp/runtime/vm/func.h"
#include "hphp/runtime/vm/jit/types.h"

namespace HPHP {

//////////////////////////////////////////////////////////////////////

/**
 * Header of the resumable frame used by async functions:
 *
 *         Header*     -> +-------------------------+ low address
 *                        | ResumableNode           |
 *                        +-------------------------+
 *                        | Function locals and     |
 *                        | iterators               |
 *         Resumable*  -> +-------------------------+
 *                        | ActRec in Resumable     |
 *                        +-------------------------+
 *                        | Rest of Resumable       |
 *         ObjectData* -> +-------------------------+
 *                        | Parent object           |
 *                        +-------------------------+ high address
 *
 * Header of the resumable frame used by generators:
 *
 *         Header*     -> +-------------------------+ low address
 *                        | ResumableNode           |
 *                        +-------------------------+
 *                        | Function locals and     |
 *                        | iterators               |
 *         Resumable*  -> +-------------------------+
 *                        | ActRec in Resumable     |
 *                        +-------------------------+
 *                        | Rest of Resumable       |
 *  BaseGenerator* ->     +-------------------------+
 *                        | Parent Generator Data   |
 *         ObjectData* -> +-------------------------+
 *                        | Parent object           |
 *                        +-------------------------+ high address
 */
struct Resumable {
  static Resumable* FromObj(ObjectData* obj);
  static const Resumable* FromObj(const ObjectData* obj);

  static constexpr ptrdiff_t arOff() {
    return offsetof(Resumable, m_actRec);
  }
  static constexpr ptrdiff_t resumeAddrOff() {
    return offsetof(Resumable, m_resumeAddr);
  }
  static constexpr ptrdiff_t resumeOffsetOff() {
    return offsetof(Resumable, m_resumeOffset);
  }
  static constexpr ptrdiff_t dataOff() {
    return sizeof(Resumable);
  }

  template<bool clone,
           size_t objSize,
           bool mayUseVV = true>
  static void* Create(const ActRec* fp,
                      size_t numSlots,
                      jit::TCA resumeAddr,
                      Offset resumeOffset) {
    assert(fp);
    assert(fp->resumed() == clone);
    auto const func = fp->func();
    assert(func);
    assert(func->isResumable());
    assert(func->contains(resumeOffset));

    // Allocate memory.
    size_t frameSize = numSlots * sizeof(TypedValue);
    size_t totalSize = sizeof(ResumableNode) + frameSize +
                       sizeof(Resumable) + objSize;
    auto node = reinterpret_cast<ResumableNode*>(MM().objMalloc(totalSize));
    auto frame = reinterpret_cast<char*>(node + 1);
    auto resumable = reinterpret_cast<Resumable*>(frame + frameSize);
    auto actRec = resumable->actRec();

    node->framesize = frameSize;
    node->hdr.kind = HeaderKind::ResumableFrame;

    if (!clone) {
      // Copy ActRec, locals and iterators
      auto src = reinterpret_cast<char*>((uintptr_t)fp - frameSize);
      wordcpy(frame, src, frameSize + sizeof(ActRec));

      // Set resumed flag.
      actRec->setResumed();

      // Suspend VarEnv if needed
      assert(mayUseVV || !(func->attrs() & AttrMayUseVV));
      if (mayUseVV &&
          UNLIKELY(func->attrs() & AttrMayUseVV) &&
          UNLIKELY(fp->hasVarEnv())) {
        fp->getVarEnv()->suspend(fp, actRec);
      }
    } else {
      // If we are cloning a Resumable, only copy the ActRec. The
      // caller will take care of copying locals, setting the VarEnv, etc.
      // When called from AFWH::Create or Generator::Create we know we are
      // going to overwrite m_sfp and m_savedRip, so don't copy them here.
      auto src = reinterpret_cast<const char*>(fp);
      auto aRec = reinterpret_cast<char*>(actRec);
      const size_t offset = offsetof(ActRec, m_func);
      wordcpy(aRec + offset, src + offset, sizeof(ActRec) - offset);
    }

    // Populate Resumable.
    resumable->m_resumeAddr = resumeAddr;
    resumable->m_offsetAndSize = (totalSize << 32 | resumeOffset);

    // Return pointer to the inline-allocated object.
    return resumable + 1;
  }

  template<class T> static void Destroy(size_t size, T* obj) {
    auto const base = reinterpret_cast<char*>(obj + 1) - size;
    obj->~T();
    MM().objFree(base, size);
  }

  ActRec* actRec() { return &m_actRec; }
  const ActRec* actRec() const { return &m_actRec; }
  jit::TCA resumeAddr() const { return m_resumeAddr; }
  Offset resumeOffset() const {
    assert(m_actRec.func()->contains(m_resumeOffset));
    return m_resumeOffset;
  }
  size_t size() const { return m_size; }

  void setResumeAddr(jit::TCA resumeAddr, Offset resumeOffset) {
    assert(m_actRec.func()->contains(resumeOffset));
    m_resumeAddr = resumeAddr;
    m_resumeOffset = resumeOffset;
  }

private:
  // ActRec of the resumed frame.
  ActRec m_actRec;

  // Resume address.
  jit::TCA m_resumeAddr;

  // Resume offset: bytecode offset from start of Unit's bytecode.
  union {
    struct {
      Offset m_resumeOffset;

      // Size of the smart allocated memory that includes this resumable.
      int32_t m_size;
    };
    uint64_t m_offsetAndSize;
  };
} __attribute__((__aligned__(16)));

static_assert(Resumable::arOff() == 0,
              "ActRec must be in the beginning of Resumable");

//////////////////////////////////////////////////////////////////////

}

#endif
