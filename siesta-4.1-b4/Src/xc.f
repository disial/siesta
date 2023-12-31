! 
! Copyright (C) 1996-2016	The SIESTA group
!  This file is distributed under the terms of the
!  GNU General Public License: see COPYING in the top directory
!  or http://www.gnu.org/copyleft/gpl.txt.
! See Docs/Contributors.txt for a list of contributors.
!
! *******************************************************************
! This file contains XC subroutines used when siesta is compiled with
! option BSC_CELLXC. Otherwise, the SiestaXC library is used.
! *******************************************************************

      subroutine atomxc( IREL, NR, MAXR, RMESH, nspin, Dens, 
     .                   EX, EC, DX, DC, VXC )

C *******************************************************************
C Finds total exchange-correlation energy and potential for a
C spherical electron density distribution.
C This version implements the Local (spin) Density Approximation and
C the Generalized-Gradient-Aproximation with the 'explicit mesh 
C functional' approach of White & Bird, PRB 50, 4954 (1994).
C Gradients are 'defined' by numerical derivatives, using 2*NN+1 mesh
C   points, where NN is a parameter defined below
C Ref: L.C.Balbas et al, PRB 64, 165110 (2001)
C Wrtten by J.M.Soler using algorithms developed by 
C   L.C.Balbas, J.L.Martins and J.M.Soler, Dec.1996
C ************************* INPUT ***********************************
C CHARACTER*(*) FUNCTL : Functional to be used:
C              'LDA' or 'LSD' => Local (spin) Density Approximation
C                       'GGA' => Generalized Gradient Corrections
C                                Uppercase is optional
C CHARACTER*(*) AUTHOR : Parametrization desired:
C     'CA' or 'PZ' => LSD Perdew & Zunger, PRB 23, 5075 (1981)
C           'PW91' => GGA Perdew & Wang, JCP, 100, 1290 (1994) 
C           'PW92' => LSD Perdew & Wang, PRB, 45, 13244 (1992). This is
C                     the local density limit of the next:
C            'PBE' => GGA Perdew, Burke & Ernzerhof, PRL 77, 3865 (1996)
C           'RPBE' => GGA Hammer, Hansen & Norskov, PRB 59, 7413 (1999)
C         'REVPBE' => GGA Zhang & Yang, PRL 80,890(1998)
C            'LYP' => GGA Becke-Lee-Yang-Parr (see subroutine blypxc)
C            'WC'  => GGA Wu-Cohen (see subroutine wcxc)
C         'PBESOL' => GGA Perdew et al, PRL, 100, 136406 (2008)
C                     Uppercase is optional
C INTEGER IREL         : Relativistic exchange? (0=>no, 1=>yes)
C INTEGER NR           : Number of radial mesh points
C INTEGER MAXR         : Physical first dimension of RMESH, Dens and VXC
C REAL*8  RMESH(MAXR)  : Radial mesh points
C INTEGER nspin        : nspin=1 => unpolarized; nspin=2 => polarized
C REAL*8  Dens(MAXR,nspin) : Total (nspin=1) or spin (nspin=2) electron
C                            density at mesh points
C ************************* OUTPUT **********************************
C REAL*8  EX              : Total exchange energy
C REAL*8  EC              : Total correlation energy
C REAL*8  DX              : IntegralOf( rho * (eps_x - v_x) )
C REAL*8  DC              : IntegralOf( rho * (eps_c - v_c) )
C REAL*8  VXC(MAXR,nspin) : (Spin) exch-corr potential
C ************************ UNITS ************************************
C Distances in atomic units (Bohr).
C Densities in atomic units (electrons/Bohr**3)
C Energy unit depending of parameter EUNIT below
C ********* ROUTINES CALLED *****************************************
C GGAXC, LDAXC
C *******************************************************************

      use precision, only : dp
      use bsc_xcmod,     only : nXCfunc, XCfunc, XCauth
      use bsc_xcmod,     only : XCweightX, XCweightC
      use sys,       only: die
      use alloc,     only: re_alloc, de_alloc

C Next line is nonstandard but may be suppressed
      implicit none

C Argument types and dimensions
      integer,   intent(in)  :: IREL
      integer,   intent(in)  :: MAXR
      integer,   intent(in)  :: NR
      integer,   intent(in)  :: nspin
      real(dp),  intent(in)  :: Dens(MAXR,nspin)
      real(dp),  intent(in)  :: RMESH(MAXR)
      real(dp),  intent(out) :: VXC(MAXR,nspin)
      real(dp),  intent(out) :: DC
      real(dp),  intent(out) :: DX
      real(dp),  intent(out) :: EC
      real(dp),  intent(out) :: EX

C Internal parameters
C NN    : order of the numerical derivatives: the number of radial 
C          points used is 2*NN+1
C mspin : must be equal or larger than nspin (4 for non-collinear spin)
      integer,   parameter   :: mspin = 4
      integer,   parameter   :: NN = 5

C Fix energy unit:  EUNIT=1.0 => Hartrees,
C                   EUNIT=0.5 => Rydbergs,
C                   EUNIT=0.03674903 => eV
      real(dp),  parameter   :: EUNIT = 0.5_dp

C DVMIN is added to differential of volume to avoid division by zero
      real(dp),  parameter   :: DVMIN = 1.0d-12

C Local variables and arrays
      logical
     .  GGA, GGAfunc
      integer
     .  IN, IN1, IN2, IR, IS, JN, NF
      real(dp)
     .  D(mspin), DECDD(mspin), DECDGD(3,mspin),
     .  DEXDD(mspin), DEXDGD(3,mspin),
     .  DGDM(-NN:NN), DGIDFJ(-NN:NN), DRDM, DVol, 
     .  DVCDN(mspin,mspin), DVXDN(mspin,mspin),
     .  EPSC, EPSX, F1, F2, GD(3,mspin), PI
      real(dp), pointer :: Aux(:)
      external
     .  GGAXC, LDAXC

C Set GGA switch
      GGA = .false.
      do nf = 1,nXCfunc
        if ( XCfunc(nf).eq.'GGA' .or. XCfunc(nf).eq.'gga') then
          GGA = .true.
        else
          if ( XCfunc(nf).ne.'LDA' .and. XCfunc(nf).ne.'lda' .and.
     .         XCfunc(nf).ne.'LSD' .and. XCfunc(nf).ne.'lsd' ) then
            call die('ATOMXC: Unknown functional ' // XCfunc(nf))
          endif 
        endif
      enddo

C Initialize output
      EX = 0.0_dp
      EC = 0.0_dp
      DX = 0.0_dp
      DC = 0.0_dp
      do IS = 1,nspin
        do IR = 1,NR
          VXC(IR,IS) = 0.0_dp
        enddo
      enddo

C Set up workspace array
      if (GGA) then
        nullify( Aux )
        call re_alloc( AUX, 1, NR, 'AUX', 'atomxc' )
      endif

C Get number pi
      PI = 4.0_dp * ATAN(1.0_dp)

C Loop on mesh points
      do IR = 1,NR

C Find interval of neighbour points to calculate derivatives
        IN1 = MAX(  1, IR-NN ) - IR
        IN2 = MIN( NR, IR+NN ) - IR

C Find weights of numerical derivation from Lagrange
C interpolation formula
        do IN = IN1,IN2
          IF (IN .EQ. 0) THEN
            DGDM(IN) = 0
            do JN = IN1,IN2
              IF (JN.NE.0) DGDM(IN) = DGDM(IN) + 1.D0 / (0 - JN)
            enddo
          ELSE
            F1 = 1
            F2 = 1
            do JN = IN1,IN2
              IF (JN.NE.IN .AND. JN.NE.0) F1 = F1 * (0  - JN)
              IF (JN.NE.IN)               F2 = F2 * (IN - JN)
            enddo
            DGDM(IN) = F1 / F2
          ENDIF
        enddo

C Find dr/dmesh
        DRDM = 0.0_dp
        do IN = IN1,IN2
          DRDM = DRDM + RMESH(IR+IN) * DGDM(IN)
        enddo

C Find differential of volume. Use trapezoidal integration rule
        DVol = 4.0_dp * PI * RMESH(IR)**2 * DRDM
C DVMIN is a small number added to avoid a division by zero
        DVol = DVol + DVMIN
        if (IR.eq.1 .or. IR.eq.NR) DVol = 0.5_dp*DVol
        if (GGA) Aux(IR) = DVol

C Find the weights for the derivative d(gradF(i))/d(F(j)), of
C the gradient at point i with respect to the value at point j
        if (GGA) then
          do IN = IN1,IN2
            DGIDFJ(IN) = DGDM(IN) / DRDM
          enddo
        endif

C Find density and gradient of density at this point
        do IS = 1,nspin
          D(IS) = Dens(IR,IS)
        enddo
        if (GGA) then
          do IS = 1,nspin
            GD(1,IS) = 0.0_dp
            GD(2,IS) = 0.0_dp
            GD(3,IS) = 0.0_dp
            do IN = IN1,IN2
              GD(3,IS) = GD(3,IS) + DGIDFJ(IN) * Dens(IR+IN,IS)
            enddo
          enddo
        endif

C Loop over exchange-correlation functions
        do nf = 1,nXCfunc

C Is this a GGA?
          if (XCfunc(nf).eq.'GGA' .or. XCfunc(nf).eq.'gga') then
            GGAfunc = .true.
          else
            GGAfunc = .false.
          endif

C Find exchange and correlation energy densities and their 
C derivatives with respect to density and density gradient
          if (GGAfunc) then
            CALL GGAXC( XCauth(nf), IREL, nspin, D, GD,
     .                  EPSX, EPSC, DEXDD, DECDD, DEXDGD, DECDGD )
          else
            CALL LDAXC( XCauth(nf), IREL, nspin, D, EPSX, EPSC, DEXDD, 
     .                  DECDD, DVXDN, DVCDN )
          endif

C Scale terms by weights
          EPSX = EPSX*XCweightX(nf)
          EPSC = EPSC*XCweightC(nf)
          DEXDD(1:nspin) = DEXDD(1:nspin)*XCweightX(nf)
          DECDD(1:nspin) = DECDD(1:nspin)*XCweightC(nf)
          if (GGAfunc) then
            DEXDGD(1:3,1:nspin) = DEXDGD(1:3,1:nspin)*XCweightX(nf)
            DECDGD(1:3,1:nspin) = DECDGD(1:3,1:nspin)*XCweightC(nf)
          endif

C Add contributions to exchange-correlation energy and its
C derivatives with respect to density at all points
          do IS = 1,nspin
            EX = EX + DVol*D(IS)*EPSX
            EC = EC + DVol*D(IS)*EPSC
            DX = DX + DVol*D(IS)*(EPSX - DEXDD(IS))
            DC = DC + DVol*D(IS)*(EPSC - DECDD(IS))
            if (GGAfunc) then
              VXC(IR,IS) = VXC(IR,IS) + DVol*(DEXDD(IS) + DECDD(IS))
              do IN = IN1,IN2
                DX= DX - DVol*Dens(IR+IN,IS)*DEXDGD(3,IS)*DGIDFJ(IN)
                DC= DC - DVol*Dens(IR+IN,IS)*DECDGD(3,IS)*DGIDFJ(IN)
                VXC(IR+IN,IS) = VXC(IR+IN,IS) + 
     .            DVol*(DEXDGD(3,IS) + DECDGD(3,IS))*DGIDFJ(IN)
              enddo
            else
              if (GGA) then
                VXC(IR,IS) = VXC(IR,IS) + DVol*(DEXDD(IS) + DECDD(IS))
              else
                VXC(IR,IS) = VXC(IR,IS) + DEXDD(IS) + DECDD(IS)
              endif
            endif
          enddo

        enddo

      enddo

C Divide by volume element to obtain the potential (per electron)
      if (GGA) then
        do IS = 1,NSPIN
          do IR = 1,NR
            DVol = AUX(IR)
            VXC(IR,IS) = VXC(IR,IS) / DVol
          enddo
        enddo
        call de_alloc( AUX, 'AUX', 'atomxc' )
      endif

C Divide by energy unit
      EX = EX / EUNIT
      EC = EC / EUNIT
      DX = DX / EUNIT
      DC = DC / EUNIT
      do IS = 1,nspin
        do IR = 1,NR
          VXC(IR,IS) = VXC(IR,IS) / EUNIT
        enddo
      enddo

      end


      subroutine exchng( IREL, NSP, DS, EX, VX )

C *****************************************************************
C  Finds local exchange energy density and potential
C  Adapted by J.M.Soler from routine velect of Froyen's 
C    pseudopotential generation program. Madrid, Jan'97. Version 0.5.
C **** Input ******************************************************
C INTEGER IREL    : relativistic-exchange switch (0=no, 1=yes)
C INTEGER NSP     : spin-polarizations (1=>unpolarized, 2=>polarized)
C REAL*8  DS(NSP) : total (nsp=1) or spin (nsp=2) electron density
C **** Output *****************************************************
C REAL*8  EX      : exchange energy density
C REAL*8  VX(NSP) : (spin-dependent) exchange potential
C **** Units ******************************************************
C Densities in electrons/Bohr**3
C Energies in Hartrees
C *****************************************************************

      use precision, only: dp
      implicit none

      integer, intent(in) :: nsp, irel
      real(dp), intent(in)             :: DS(NSP)
      real(dp), intent(out)            :: VX(NSP)
      real(dp), intent(out)            :: EX

      real(dp), parameter :: zero = 0.0_dp, one = 1.0_dp
      real(dp), parameter :: pfive = 0.5_dp, opf = 1.5_dp
      real(dp), parameter :: C014 = 0.014_dp

      real(dp) :: pi, trd, ftrd, tftm, a0
      real(dp) :: alp, d1, d2, d, z, fz, fzp, rs, vxp, exp_var
      real(dp) :: beta, sb, vxf, exf, alb

      PI=4*ATAN(ONE)
      TRD = ONE/3
      FTRD = 4*TRD
      TFTM = 2**FTRD-2
      A0 = (4/(9*PI))**TRD

C X-alpha parameter:       
      ALP = 2 * TRD

      IF (NSP .EQ. 2) THEN
        D1 = MAX(DS(1),0.D0)
        D2 = MAX(DS(2),0.D0)
        D = D1 + D2
        IF (D .LE. ZERO) THEN
          EX = ZERO
          VX(1) = ZERO
          VX(2) = ZERO
          RETURN
        ENDIF
        Z = (D1 - D2) / D
        FZ = ((1+Z)**FTRD+(1-Z)**FTRD-2)/TFTM
        FZP = FTRD*((1+Z)**TRD-(1-Z)**TRD)/TFTM 
      ELSE
        D = DS(1)
        IF (D .LE. ZERO) THEN
          EX = ZERO
          VX(1) = ZERO
          RETURN
        ENDIF
        Z = ZERO
        FZ = ZERO
        FZP = ZERO
      ENDIF
      RS = (3 / (4*PI*D) )**TRD
      VXP = -(3*ALP/(2*PI*A0*RS))
      EXP_VAR = 3*VXP/4
      IF (IREL .EQ. 1) THEN
        BETA = C014/RS
        SB = SQRT(1+BETA*BETA)
        ALB = LOG(BETA+SB)
        VXP = VXP * (-PFIVE + OPF * ALB / (BETA*SB))
        EXP_VAR = EXP_VAR * (ONE-OPF*((BETA*SB-ALB)/BETA**2)**2) 
      ENDIF
      VXF = 2**TRD*VXP
      EXF = 2**TRD*EXP_VAR
      IF (NSP .EQ. 2) THEN
        VX(1) = VXP + FZ*(VXF-VXP) + (1-Z)*FZP*(EXF-EXP_VAR)
        VX(2) = VXP + FZ*(VXF-VXP) - (1+Z)*FZP*(EXF-EXP_VAR)
        EX    = EXP_VAR + FZ*(EXF-EXP_VAR)
      ELSE
        VX(1) = VXP
        EX    = EXP_VAR
      ENDIF
      END

      SUBROUTINE GGAXC( AUTHOR, IREL, nspin, D, GD,
     .                  EPSX, EPSC, DEXDD, DECDD, DEXDGD, DECDGD )

C Finds the exchange and correlation energies at a point, and their
C derivatives with respect to density and density gradient, in the
C Generalized Gradient Correction approximation.
C Lengths in Bohr, energies in Hartrees
C Written by L.C.Balbas and J.M.Soler, Dec'96. Version 0.5.
C Modified by V.M.Garcia-Suarez to include non-collinear spin. June 2002

      use precision, only : dp
      use sys,       only : die

      implicit          none

      CHARACTER*(*)     AUTHOR
      INTEGER           IREL, nspin, NS, IS, IX
      real(dp)          THETA, PHI, D(nspin), DECDD(nspin),
     .                  DECDGD(3,nspin), DEXDD(nspin), DEXDGD(3,nspin),
     .                  EPSC, EPSX, GD(3,nspin),
     .                  DD(2), DTOT, DPOL,
     .                  GDD(3,2), TINY, DECDN(2), DEXDN(2),
     .                  VPOL, DECDGN(3,2), DEXDGN(3,2),
     .                  C2, S2, ST, CT, CP, SP, dpolz, dpolxy


      PARAMETER ( TINY = 1.D-12 )

      IF (nspin .EQ. 4) THEN
C Find eigenvalues of density matrix (up and down densities
C along the spin direction)
C Note: D(1)=D11, D(2)=D22, D(3)=Real(D12), D(4)=Im(D12)
        NS = 2
        DTOT = D(1) + D(2)

!    Explicit calculation of the rotation-matrix elements from
!    the entries of D

        dpolz= D(1)-D(2)
        dpolxy= 2.0d0*sqrt(D(3)**2+D(4)**2)
        DPOL  = sqrt( dpolz**2 + dpolxy**2 )
        if ( DPOL.gt.1.0d-12 ) then
         THETA = atan2(dpolxy,dpolz)
        else
         THETA = 0.0_dp
        endif
        C2 = COS(THETA/2)
        S2 = SIN(THETA/2)
        ST = SIN(THETA)
        CT = COS(THETA)
        PHI = ATAN2(-D(4),D(3))
        CP = COS(PHI)
        SP = SIN(PHI)

        DD(1) = 0.5D0 * ( DTOT + DPOL )
        DD(2) = 0.5D0 * ( DTOT - DPOL )

C Find diagonal elements of the gradient
        DO IX = 1,3
          GDD(IX,1) = GD(IX,1)*C2**2 + GD(IX,2)*S2**2 +
     .                2.d0*C2*S2*(GD(IX,3)*CP - GD(IX,4)*SP)
          GDD(IX,2) = GD(IX,1)*S2**2 + GD(IX,2)*C2**2 -
     .                2.d0*C2*S2*(GD(IX,3)*CP - GD(IX,4)*SP)
        ENDDO
      ELSE
        NS = nspin
        DO 20 IS = 1,nspin
cag       Avoid negative densities
          DD(IS) = max(D(IS),0.0d0)
          DO 30 IX = 1,3
            GDD(IX,IS) = GD(IX,IS)
   30     CONTINUE
   20   CONTINUE
      ENDIF

      IF (AUTHOR.EQ.'PBE' .OR. AUTHOR.EQ.'pbe') THEN
        CALL PBEXC( IREL, NS, DD, GDD,
     .              EPSX, EPSC, DEXDN, DECDN, DEXDGN, DECDGN )
cmvfs
      ELSE IF (AUTHOR.EQ.'RPBE'.OR.AUTHOR.EQ.'rpbe') THEN
        CALL RPBEXC( IREL, NS, DD, GDD,
     .               EPSX, EPSC, DEXDN, DECDN, DEXDGN, DECDGN )
cmvfs
      ELSE IF (AUTHOR.EQ.'WC'.OR.AUTHOR.EQ.'wc') THEN
        CALL WCXC( IREL, NS, DD, GDD,
     .               EPSX, EPSC, DEXDN, DECDN, DEXDGN, DECDGN )
cea
      ELSE IF (AUTHOR.EQ.'REVPBE'.OR.AUTHOR.EQ.'revpbe'
     .                           .OR.AUTHOR.EQ.'revPBE') THEN
        CALL REVPBEXC( IREL, NS, DD, GDD,
     .               EPSX, EPSC, DEXDN, DECDN, DEXDGN, DECDGN )
cag
      ELSE IF (AUTHOR.EQ.'LYP'.OR.AUTHOR.EQ.'lyp') THEN
        CALL BLYPXC( NS, DD, GDD, EPSX, EPSC, dEXdn, dECdn,
     .               DEXDGN, DECDGN)
cag
      ELSEIF (AUTHOR.EQ.'PW91' .OR. AUTHOR.EQ.'pw91') THEN
        CALL PW91XC( IREL, NS, DD, GDD,
     .               EPSX, EPSC, DEXDN, DECDN, DEXDGN, DECDGN )
cjdg
      ELSEIF (AUTHOR.EQ.'PBESOL'.OR.AUTHOR.EQ.'pbesol'
     .                           .OR.AUTHOR.EQ.'PBEsol') THEN
        CALL PBESOLXC( IREL, NS, DD, GDD,
     .               EPSX, EPSC, DEXDN, DECDN, DEXDGN, DECDGN )
      ELSE
        call die('GGAXC: Unknown author ' // trim(AUTHOR))
      ENDIF

      IF (nspin .EQ. 4) THEN
C Find dE/dD(ispin) = dE/dDup * dDup/dD(ispin) +
C                     dE/dDdown * dDown/dD(ispin)
C Note convention: 
C       DEDD(1)=dE/dD11, DEDD(2)=dE/dD22,
C       DEDD(3)=Re(dE/dD12)=Re(dE/dD21), 
C       DEDD(4)=Im(dE/dD12)=-Im(dE/D21)
C
        VPOL  = (DEXDN(1)-DEXDN(2)) * CT
        DEXDD(1) = 0.5D0 * ( DEXDN(1) + DEXDN(2) + VPOL )
        DEXDD(2) = 0.5D0 * ( DEXDN(1) + DEXDN(2) - VPOL )
        DEXDD(3) = 0.5d0 * (DEXDN(1)-DEXDN(2)) * ST * CP
        DEXDD(4) =-0.5d0 * (DEXDN(1)-DEXDN(2)) * ST * SP
        VPOL  = (DECDN(1)-DECDN(2)) * CT
        DECDD(1) = 0.5D0 * ( DECDN(1) + DECDN(2) + VPOL )
        DECDD(2) = 0.5D0 * ( DECDN(1) + DECDN(2) - VPOL )
        DECDD(3) = 0.5d0 * (DECDN(1)-DECDN(2)) * ST * CP
        DECDD(4) =-0.5d0 * (DECDN(1)-DECDN(2)) * ST * SP
C Gradient terms
        DO 40 IX = 1,3
          DEXDGD(IX,1) = DEXDGN(IX,1)*C2**2 + DEXDGN(IX,2)*S2**2
          DEXDGD(IX,2) = DEXDGN(IX,1)*S2**2 + DEXDGN(IX,2)*C2**2
          DEXDGD(IX,3) = 0.5D0*(DEXDGN(IX,1) - DEXDGN(IX,2))*ST*CP
          DEXDGD(IX,4) =-0.5D0*(DEXDGN(IX,1) - DEXDGN(IX,2))*ST*SP
          DECDGD(IX,1) = DECDGN(IX,1)*C2**2 + DECDGN(IX,2)*S2**2
          DECDGD(IX,2) = DECDGN(IX,1)*S2**2 + DECDGN(IX,2)*C2**2
          DECDGD(IX,3) = 0.5D0*(DECDGN(IX,1) - DECDGN(IX,2))*ST*CP
          DECDGD(IX,4) =-0.5D0*(DECDGN(IX,1) - DECDGN(IX,2))*ST*SP
   40   CONTINUE
      ELSE
        DO 60 IS = 1,nspin
          DEXDD(IS) = DEXDN(IS)
          DECDD(IS) = DECDN(IS)
          DO 50 IX = 1,3
            DEXDGD(IX,IS) = DEXDGN(IX,IS)
            DECDGD(IX,IS) = DECDGN(IX,IS)
   50     CONTINUE
   60   CONTINUE
      ENDIF

      END


      SUBROUTINE LDAXC( AUTHOR, IREL, nspin, D, EPSX, EPSC, VX, VC,
     .                  DVXDN, DVCDN )

C ******************************************************************
C Finds the exchange and correlation energies and potentials, in the
C Local (spin) Density Approximation.
C Written by L.C.Balbas and J.M.Soler, Dec'96.
C Non-collinear spin added by J.M.Soler, May'98
C *********** INPUT ************************************************
C CHARACTER*(*) AUTHOR : Parametrization desired:
C     'CA' or 'PZ' => LSD Perdew & Zunger, PRB 23, 5075 (1981)
C           'PW92' => LSD Perdew & Wang, PRB, 45, 13244 (1992)
C                     Uppercase is optional
C INTEGER IREL     : Relativistic exchange? (0=>no, 1=>yes)
C INTEGER nspin    : nspin=1 => unpolarized; nspin=2 => polarized;
C                    nspin=4 => non-collinear polarization
C REAL*8  D(nspin) : Local (spin) density. For non-collinear
C                    polarization, the density matrix is given by:
C                    D(1)=D11, D(2)=D22, D(3)=Real(D12), D(4)=Im(D12)
C *********** OUTPUT ***********************************************
C REAL*8 EPSX, EPSC : Exchange and correlation energy densities
C REAL*8 VX(nspin), VC(nspin) : Exchange and correlation potentials,
C                               defined as dExc/dD(ispin)
C REAL*8 DVXDN(nspin,nspin)  :  Derivative of exchange potential with
C                               respect the charge density, defined 
C                               as DVx(spin1)/Dn(spin2)
C REAL*8 DVCDN(nspin,nspin)  :  Derivative of correlation potential
C                               respect the charge density, defined 
C                               as DVc(spin1)/Dn(spin2)
C *********** UNITS ************************************************
C Lengths in Bohr, energies in Hartrees
C ******************************************************************

      use precision, only : dp
      use sys,       only : die

      implicit          none

      CHARACTER*(*)     AUTHOR
      INTEGER           IREL, nspin
      real(dp)          D(nspin), EPSC, EPSX, VX(nspin), VC(nspin),
     .                  DVXDN(nspin,nspin), DVCDN(nspin,nspin)

      INTEGER           IS, NS, ISPIN1, ISPIN2
      real(dp)          DD(2), DPOL, DTOT, TINY, VCD(2), VPOL, VXD(2)

      PARAMETER ( TINY = 1.D-12 )

      IF (nspin .EQ. 4) THEN
C Find eigenvalues of density matrix (up and down densities
C along the spin direction)
C Note: D(1)=D11, D(2)=D22, D(3)=Real(D12), D(4)=Im(D12)
        NS = 2
        DTOT = D(1) + D(2)
        DPOL = SQRT( (D(1)-D(2))**2 + 4.D0*(D(3)**2+D(4)**2) )
        DD(1) = 0.5D0 * ( DTOT + DPOL )
        DD(2) = 0.5D0 * ( DTOT - DPOL )
      ELSE
        NS = nspin
        DO 10 IS = 1,nspin
cag       Avoid negative densities
          DD(IS) = max(D(IS),0.0d0)
   10   CONTINUE
      ENDIF


      DO ISPIN2 = 1, nspin
        DO ISPIN1 = 1, nspin
          DVXDN(ISPIN1,ISPIN2) = 0.D0
          DVCDN(ISPIN1,ISPIN2) = 0.D0
        ENDDO
      ENDDO

      IF ( AUTHOR.EQ.'CA' .OR. AUTHOR.EQ.'ca' .OR.
     .     AUTHOR.EQ.'PZ' .OR. AUTHOR.EQ.'pz') THEN
        CALL PZXC( IREL, NS, DD, EPSX, EPSC, VXD, VCD, DVXDN, DVCDN )
      ELSEIF ( AUTHOR.EQ.'PW92' .OR. AUTHOR.EQ.'pw92' ) THEN
        CALL PW92XC( IREL, NS, DD, EPSX, EPSC, VXD, VCD )
      ELSE
        call die('LDAXC: Unknown author ' // trim(AUTHOR))
      ENDIF

      IF (nspin .EQ. 4) THEN
C Find dE/dD(ispin) = dE/dDup * dDup/dD(ispin) +
C                     dE/dDdown * dDown/dD(ispin)
        VPOL  = (VXD(1)-VXD(2)) * (D(1)-D(2)) / (DPOL+TINY)
        VX(1) = 0.5D0 * ( VXD(1) + VXD(2) + VPOL )
        VX(2) = 0.5D0 * ( VXD(1) + VXD(2) - VPOL )
        VX(3) = (VXD(1)-VXD(2)) * D(3) / (DPOL+TINY)
        VX(4) = (VXD(1)-VXD(2)) * D(4) / (DPOL+TINY)
        VPOL  = (VCD(1)-VCD(2)) * (D(1)-D(2)) / (DPOL+TINY)
        VC(1) = 0.5D0 * ( VCD(1) + VCD(2) + VPOL )
        VC(2) = 0.5D0 * ( VCD(1) + VCD(2) - VPOL )
        VC(3) = (VCD(1)-VCD(2)) * D(3) / (DPOL+TINY)
        VC(4) = (VCD(1)-VCD(2)) * D(4) / (DPOL+TINY)
      ELSE
        DO 20 IS = 1,nspin
          VX(IS) = VXD(IS)
          VC(IS) = VCD(IS)
   20   CONTINUE
      ENDIF
      END


      SUBROUTINE PBEXC( IREL, nspin, Dens, GDens,
     .                  EX, EC, DEXDD, DECDD, DEXDGD, DECDGD )

C *********************************************************************
C Implements Perdew-Burke-Ernzerhof Generalized-Gradient-Approximation.
C Ref: J.P.Perdew, K.Burke & M.Ernzerhof, PRL 77, 3865 (1996)
C Written by L.C.Balbas and J.M.Soler. December 1996. Version 0.5.
C ******** INPUT ******************************************************
C INTEGER IREL           : Relativistic-exchange switch (0=No, 1=Yes)
C INTEGER nspin          : Number of spin polarizations (1 or 2)
C REAL*8  Dens(nspin)    : Total electron density (if nspin=1) or
C                           spin electron density (if nspin=2)
C REAL*8  GDens(3,nspin) : Total or spin density gradient
C ******** OUTPUT *****************************************************
C REAL*8  EX             : Exchange energy density
C REAL*8  EC             : Correlation energy density
C REAL*8  DEXDD(nspin)   : Partial derivative
C                           d(DensTot*Ex)/dDens(ispin),
C                           where DensTot = Sum_ispin( Dens(ispin) )
C                          For a constant density, this is the
C                          exchange potential
C REAL*8  DECDD(nspin)   : Partial derivative
C                           d(DensTot*Ec)/dDens(ispin),
C                           where DensTot = Sum_ispin( Dens(ispin) )
C                          For a constant density, this is the
C                          correlation potential
C REAL*8  DEXDGD(3,nspin): Partial derivative
C                           d(DensTot*Ex)/d(GradDens(i,ispin))
C REAL*8  DECDGD(3,nspin): Partial derivative
C                           d(DensTot*Ec)/d(GradDens(i,ispin))
C ********* UNITS ****************************************************
C Lengths in Bohr
C Densities in electrons per Bohr**3
C Energies in Hartrees
C Gradient vectors in cartesian coordinates
C ********* ROUTINES CALLED ******************************************
C EXCHNG, PW92C
C ********************************************************************

      use precision, only : dp

      implicit          none
      INTEGER           IREL, nspin
      real(dp)          Dens(nspin), DECDD(nspin), DECDGD(3,nspin),
     .                  DEXDD(nspin), DEXDGD(3,nspin), GDens(3,nspin)

C Internal variables
      INTEGER
     .  IS, IX

      real(dp)
     .  A, BETA, D(2), DADD, DECUDD, DENMIN, 
     .  DF1DD, DF2DD, DF3DD, DF4DD, DF1DGD, DF3DGD, DF4DGD,
     .  DFCDD(2), DFCDGD(3,2), DFDD, DFDGD, DFXDD(2), DFXDGD(3,2),
     .  DHDD, DHDGD, DKFDD, DKSDD, DPDD, DPDZ, DRSDD, 
     .  DS(2), DSDD, DSDGD, DT, DTDD, DTDGD, DZDD(2), 
     .  EC, ECUNIF, EX, EXUNIF,
     .  F, F1, F2, F3, F4, FC, FX, FOUTHD,
     .  GAMMA, GD(3,2), GDM(2), GDMIN, GDMS, GDMT, GDS, GDT(3),
     .  H, HALF, KAPPA, KF, KFS, KS, MU, PHI, PI, RS, S,
     .  T, THD, THRHLF, TWO, TWOTHD, VCUNIF(2), VXUNIF(2), ZETA

C Lower bounds of density and its gradient to avoid divisions by zero
      PARAMETER ( DENMIN = 1.D-12 )
      PARAMETER ( GDMIN  = 1.D-12 )

C Fix some numerical parameters
      PARAMETER ( FOUTHD=4.D0/3.D0, HALF=0.5D0,
     .            THD=1.D0/3.D0, THRHLF=1.5D0,
     .            TWO=2.D0, TWOTHD=2.D0/3.D0 )

C Fix some more numerical constants
      PI = 4 * ATAN(1.D0)
      BETA = 0.066725D0
      GAMMA = (1 - LOG(TWO)) / PI**2
      MU = BETA * PI**2 / 3
      KAPPA = 0.804D0

C Translate density and its gradient to new variables
      IF (nspin .EQ. 1) THEN
        D(1) = HALF * Dens(1)
        D(2) = D(1)
        DT = MAX( DENMIN, Dens(1) )
        DO 10 IX = 1,3
          GD(IX,1) = HALF * GDens(IX,1)
          GD(IX,2) = GD(IX,1)
          GDT(IX) = GDens(IX,1)
   10   CONTINUE
      ELSE
        D(1) = Dens(1)
        D(2) = Dens(2)
        DT = MAX( DENMIN, Dens(1)+Dens(2) )
        DO 20 IX = 1,3
          GD(IX,1) = GDens(IX,1)
          GD(IX,2) = GDens(IX,2)
          GDT(IX) = GDens(IX,1) + GDens(IX,2)
   20   CONTINUE
      ENDIF
      GDM(1) = SQRT( GD(1,1)**2 + GD(2,1)**2 + GD(3,1)**2 )
      GDM(2) = SQRT( GD(1,2)**2 + GD(2,2)**2 + GD(3,2)**2 )
      GDMT   = SQRT( GDT(1)**2  + GDT(2)**2  + GDT(3)**2  )
      GDMT = MAX( GDMIN, GDMT )

C Find local correlation energy and potential
      CALL PW92C( 2, D, ECUNIF, VCUNIF )

C Find total correlation energy
      RS = ( 3 / (4*PI*DT) )**THD
      KF = (3 * PI**2 * DT)**THD
      KS = SQRT( 4 * KF / PI )
      ZETA = ( D(1) - D(2) ) / DT
      ZETA = MAX( -1.D0+DENMIN, ZETA )
      ZETA = MIN(  1.D0-DENMIN, ZETA )
      PHI = HALF * ( (1+ZETA)**TWOTHD + (1-ZETA)**TWOTHD )
      T = GDMT / (2 * PHI * KS * DT)
      F1 = ECUNIF / GAMMA / PHI**3
      F2 = EXP(-F1)
      A = BETA / GAMMA / (F2-1)
      F3 = T**2 + A * T**4
      F4 = BETA/GAMMA * F3 / (1 + A*F3)
      H = GAMMA * PHI**3 * LOG( 1 + F4 )
      FC = ECUNIF + H

C Find correlation energy derivatives
      DRSDD = - (THD * RS / DT)
      DKFDD =   THD * KF / DT
      DKSDD = HALF * KS * DKFDD / KF
      DZDD(1) =   1 / DT - ZETA / DT
      DZDD(2) = - (1 / DT) - ZETA / DT
      DPDZ = HALF * TWOTHD * ( 1/(1+ZETA)**THD - 1/(1-ZETA)**THD )
      DO 40 IS = 1,2
        DECUDD = ( VCUNIF(IS) - ECUNIF ) / DT
        DPDD = DPDZ * DZDD(IS)
        DTDD = (- T) * ( DPDD/PHI + DKSDD/KS + 1/DT )
        DF1DD = F1 * ( DECUDD/ECUNIF - 3*DPDD/PHI )
        DF2DD = (- F2) * DF1DD
        DADD = (- A) * DF2DD / (F2-1)
        DF3DD = (2*T + 4*A*T**3) * DTDD + DADD * T**4
        DF4DD = F4 * ( DF3DD/F3 - (DADD*F3+A*DF3DD)/(1+A*F3) )
        DHDD = 3 * H * DPDD / PHI
        DHDD = DHDD + GAMMA * PHI**3 * DF4DD / (1+F4)
        DFCDD(IS) = VCUNIF(IS) + H + DT * DHDD

        DO 30 IX = 1,3
          DTDGD = (T / GDMT) * GDT(IX) / GDMT
          DF3DGD = DTDGD * ( 2 * T + 4 * A * T**3 )
          DF4DGD = F4 * DF3DGD * ( 1/F3 - A/(1+A*F3) ) 
          DHDGD = GAMMA * PHI**3 * DF4DGD / (1+F4)
          DFCDGD(IX,IS) = DT * DHDGD
   30   CONTINUE
   40 CONTINUE

C Find exchange energy and potential
      FX = 0
      DO 60 IS = 1,2
        DS(IS)   = MAX( DENMIN, 2 * D(IS) )
        GDMS = MAX( GDMIN, 2 * GDM(IS) )
        KFS = (3 * PI**2 * DS(IS))**THD
        S = GDMS / (2 * KFS * DS(IS))
        F1 = 1 + MU * S**2 / KAPPA
        F = 1 + KAPPA - KAPPA / F1
c
c       Note nspin=1 in call to exchng...
c
        CALL EXCHNG( IREL, 1, DS(IS), EXUNIF, VXUNIF(IS) )
        FX = FX + DS(IS) * EXUNIF * F

        DKFDD = THD * KFS / DS(IS)
        DSDD = S * ( -(DKFDD/KFS) - 1/DS(IS) )
        DF1DD = 2 * (F1-1) * DSDD / S
        DFDD = KAPPA * DF1DD / F1**2
        DFXDD(IS) = VXUNIF(IS) * F + DS(IS) * EXUNIF * DFDD

        DO 50 IX = 1,3
          GDS = 2 * GD(IX,IS)
          DSDGD = (S / GDMS) * GDS / GDMS
          DF1DGD = 2 * MU * S * DSDGD / KAPPA
          DFDGD = KAPPA * DF1DGD / F1**2
          DFXDGD(IX,IS) = DS(IS) * EXUNIF * DFDGD
   50   CONTINUE
   60 CONTINUE
      FX = HALF * FX / DT

C Set output arguments
      EX = FX
      EC = FC
      DO 90 IS = 1,nspin
        DEXDD(IS) = DFXDD(IS)
        DECDD(IS) = DFCDD(IS)
        DO 80 IX = 1,3
          DEXDGD(IX,IS) = DFXDGD(IX,IS)
          DECDGD(IX,IS) = DFCDGD(IX,IS)
   80   CONTINUE
   90 CONTINUE

      END

      SUBROUTINE REVPBEXC( IREL, nspin, Dens, GDens,
     .                  EX, EC, DEXDD, DECDD, DEXDGD, DECDGD )

C *********************************************************************
C Implements revPBE: revised Perdew-Burke-Ernzerhof GGA.
C Ref: Y. Zhang & W. Yang, Phys. Rev. Lett. 80, 890 (1998).
C Written by E. Artacho in January 2006 by modifying the PBE routine of 
C L.C.Balbas and J.M.Soler. December 1996. Version 0.5.
C ******** INPUT ******************************************************
C INTEGER IREL           : Relativistic-exchange switch (0=No, 1=Yes)
C INTEGER nspin          : Number of spin polarizations (1 or 2)
C REAL*8  Dens(nspin)    : Total electron density (if nspin=1) or
C                           spin electron density (if nspin=2)
C REAL*8  GDens(3,nspin) : Total or spin density gradient
C ******** OUTPUT *****************************************************
C REAL*8  EX             : Exchange energy density
C REAL*8  EC             : Correlation energy density
C REAL*8  DEXDD(nspin)   : Partial derivative
C                           d(DensTot*Ex)/dDens(ispin),
C                           where DensTot = Sum_ispin( Dens(ispin) )
C                          For a constant density, this is the
C                          exchange potential
C REAL*8  DECDD(nspin)   : Partial derivative
C                           d(DensTot*Ec)/dDens(ispin),
C                           where DensTot = Sum_ispin( Dens(ispin) )
C                          For a constant density, this is the
C                          correlation potential
C REAL*8  DEXDGD(3,nspin): Partial derivative
C                           d(DensTot*Ex)/d(GradDens(i,ispin))
C REAL*8  DECDGD(3,nspin): Partial derivative
C                           d(DensTot*Ec)/d(GradDens(i,ispin))
C ********* UNITS ****************************************************
C Lengths in Bohr
C Densities in electrons per Bohr**3
C Energies in Hartrees
C Gradient vectors in cartesian coordinates
C ********* ROUTINES CALLED ******************************************
C EXCHNG, PW92C
C ********************************************************************

      use precision, only : dp

      implicit          none
      INTEGER           IREL, nspin
      real(dp)          Dens(nspin), DECDD(nspin), DECDGD(3,nspin),
     .                  DEXDD(nspin), DEXDGD(3,nspin), GDens(3,nspin)

C Internal variables
      INTEGER
     .  IS, IX

      real(dp)
     .  A, BETA, D(2), DADD, DECUDD, DENMIN, 
     .  DF1DD, DF2DD, DF3DD, DF4DD, DF1DGD, DF3DGD, DF4DGD,
     .  DFCDD(2), DFCDGD(3,2), DFDD, DFDGD, DFXDD(2), DFXDGD(3,2),
     .  DHDD, DHDGD, DKFDD, DKSDD, DPDD, DPDZ, DRSDD, 
     .  DS(2), DSDD, DSDGD, DT, DTDD, DTDGD, DZDD(2), 
     .  EC, ECUNIF, EX, EXUNIF,
     .  F, F1, F2, F3, F4, FC, FX, FOUTHD,
     .  GAMMA, GD(3,2), GDM(2), GDMIN, GDMS, GDMT, GDS, GDT(3),
     .  H, HALF, KAPPA, KF, KFS, KS, MU, PHI, PI, RS, S,
     .  T, THD, THRHLF, TWO, TWOTHD, VCUNIF(2), VXUNIF(2), ZETA

C Lower bounds of density and its gradient to avoid divisions by zero
      PARAMETER ( DENMIN = 1.D-12 )
      PARAMETER ( GDMIN  = 1.D-12 )

C Fix some numerical parameters
      PARAMETER ( FOUTHD=4.D0/3.D0, HALF=0.5D0,
     .            THD=1.D0/3.D0, THRHLF=1.5D0,
     .            TWO=2.D0, TWOTHD=2.D0/3.D0 )

C Fix some more numerical constants
      PI = 4 * ATAN(1.D0)
      BETA = 0.066725D0
      GAMMA = (1 - LOG(TWO)) / PI**2
      MU = BETA * PI**2 / 3
cea  The only modification w.r.t. PBE in this following line.
      KAPPA = 1.245D0

C Translate density and its gradient to new variables
      IF (nspin .EQ. 1) THEN
        D(1) = HALF * Dens(1)
        D(2) = D(1)
        DT = MAX( DENMIN, Dens(1) )
        DO 10 IX = 1,3
          GD(IX,1) = HALF * GDens(IX,1)
          GD(IX,2) = GD(IX,1)
          GDT(IX) = GDens(IX,1)
   10   CONTINUE
      ELSE
        D(1) = Dens(1)
        D(2) = Dens(2)
        DT = MAX( DENMIN, Dens(1)+Dens(2) )
        DO 20 IX = 1,3
          GD(IX,1) = GDens(IX,1)
          GD(IX,2) = GDens(IX,2)
          GDT(IX) = GDens(IX,1) + GDens(IX,2)
   20   CONTINUE
      ENDIF
      GDM(1) = SQRT( GD(1,1)**2 + GD(2,1)**2 + GD(3,1)**2 )
      GDM(2) = SQRT( GD(1,2)**2 + GD(2,2)**2 + GD(3,2)**2 )
      GDMT   = SQRT( GDT(1)**2  + GDT(2)**2  + GDT(3)**2  )
      GDMT = MAX( GDMIN, GDMT )

C Find local correlation energy and potential
      CALL PW92C( 2, D, ECUNIF, VCUNIF )

C Find total correlation energy
      RS = ( 3 / (4*PI*DT) )**THD
      KF = (3 * PI**2 * DT)**THD
      KS = SQRT( 4 * KF / PI )
      ZETA = ( D(1) - D(2) ) / DT
      ZETA = MAX( -1.D0+DENMIN, ZETA )
      ZETA = MIN(  1.D0-DENMIN, ZETA )
      PHI = HALF * ( (1+ZETA)**TWOTHD + (1-ZETA)**TWOTHD )
      T = GDMT / (2 * PHI * KS * DT)
      F1 = ECUNIF / GAMMA / PHI**3
      F2 = EXP(-F1)
      A = BETA / GAMMA / (F2-1)
      F3 = T**2 + A * T**4
      F4 = BETA/GAMMA * F3 / (1 + A*F3)
      H = GAMMA * PHI**3 * LOG( 1 + F4 )
      FC = ECUNIF + H

C Find correlation energy derivatives
      DRSDD = - (THD * RS / DT)
      DKFDD =   THD * KF / DT
      DKSDD = HALF * KS * DKFDD / KF
      DZDD(1) =   1 / DT - ZETA / DT
      DZDD(2) = - (1 / DT) - ZETA / DT
      DPDZ = HALF * TWOTHD * ( 1/(1+ZETA)**THD - 1/(1-ZETA)**THD )
      DO 40 IS = 1,2
        DECUDD = ( VCUNIF(IS) - ECUNIF ) / DT
        DPDD = DPDZ * DZDD(IS)
        DTDD = (- T) * ( DPDD/PHI + DKSDD/KS + 1/DT )
        DF1DD = F1 * ( DECUDD/ECUNIF - 3*DPDD/PHI )
        DF2DD = (- F2) * DF1DD
        DADD = (- A) * DF2DD / (F2-1)
        DF3DD = (2*T + 4*A*T**3) * DTDD + DADD * T**4
        DF4DD = F4 * ( DF3DD/F3 - (DADD*F3+A*DF3DD)/(1+A*F3) )
        DHDD = 3 * H * DPDD / PHI
        DHDD = DHDD + GAMMA * PHI**3 * DF4DD / (1+F4)
        DFCDD(IS) = VCUNIF(IS) + H + DT * DHDD

        DO 30 IX = 1,3
          DTDGD = (T / GDMT) * GDT(IX) / GDMT
          DF3DGD = DTDGD * ( 2 * T + 4 * A * T**3 )
          DF4DGD = F4 * DF3DGD * ( 1/F3 - A/(1+A*F3) ) 
          DHDGD = GAMMA * PHI**3 * DF4DGD / (1+F4)
          DFCDGD(IX,IS) = DT * DHDGD
   30   CONTINUE
   40 CONTINUE

C Find exchange energy and potential
      FX = 0
      DO 60 IS = 1,2
        DS(IS)   = MAX( DENMIN, 2 * D(IS) )
        GDMS = MAX( GDMIN, 2 * GDM(IS) )
        KFS = (3 * PI**2 * DS(IS))**THD
        S = GDMS / (2 * KFS * DS(IS))
        F1 = 1 + MU * S**2 / KAPPA
        F = 1 + KAPPA - KAPPA / F1
c
c       Note nspin=1 in call to exchng...
c
        CALL EXCHNG( IREL, 1, DS(IS), EXUNIF, VXUNIF(IS) )
        FX = FX + DS(IS) * EXUNIF * F

        DKFDD = THD * KFS / DS(IS)
        DSDD = S * ( -(DKFDD/KFS) - 1/DS(IS) )
        DF1DD = 2 * (F1-1) * DSDD / S
        DFDD = KAPPA * DF1DD / F1**2
        DFXDD(IS) = VXUNIF(IS) * F + DS(IS) * EXUNIF * DFDD

        DO 50 IX = 1,3
          GDS = 2 * GD(IX,IS)
          DSDGD = (S / GDMS) * GDS / GDMS
          DF1DGD = 2 * MU * S * DSDGD / KAPPA
          DFDGD = KAPPA * DF1DGD / F1**2
          DFXDGD(IX,IS) = DS(IS) * EXUNIF * DFDGD
   50   CONTINUE
   60 CONTINUE
      FX = HALF * FX / DT

C Set output arguments
      EX = FX
      EC = FC
      DO 90 IS = 1,nspin
        DEXDD(IS) = DFXDD(IS)
        DECDD(IS) = DFCDD(IS)
        DO 80 IX = 1,3
          DEXDGD(IX,IS) = DFXDGD(IX,IS)
          DECDGD(IX,IS) = DFCDGD(IX,IS)
   80   CONTINUE
   90 CONTINUE

      END


      SUBROUTINE PW91XC( IREL, nspin, Dens, GDens,
     .                  EX, EC, DEXDD, DECDD, DEXDGD, DECDGD )

C *********************************************************************
C Implements Perdew-Wang91 Generalized-Gradient-Approximation.
C Ref: JCP 100, 1290 (1994)
C Written by J.L. Martins  August 2000
C ******** INPUT ******************************************************
C INTEGER IREL           : Relativistic-exchange switch (0=No, 1=Yes)
C INTEGER nspin          : Number of spin polarizations (1 or 2)
C REAL*8  Dens(nspin)    : Total electron density (if nspin=1) or
C                           spin electron density (if nspin=2)
C REAL*8  GDens(3,nspin) : Total or spin density gradient
C ******** OUTPUT *****************************************************
C REAL*8  EX             : Exchange energy density
C REAL*8  EC             : Correlation energy density
C REAL*8  DEXDD(nspin)   : Partial derivative
C                           d(DensTot*Ex)/dDens(ispin),
C                           where DensTot = Sum_ispin( Dens(ispin) )
C                          For a constant density, this is the
C                          exchange potential
C REAL*8  DECDD(nspin)   : Partial derivative
C                           d(DensTot*Ec)/dDens(ispin),
C                           where DensTot = Sum_ispin( Dens(ispin) )
C                          For a constant density, this is the
C                          correlation potential
C REAL*8  DEXDGD(3,nspin): Partial derivative
C                           d(DensTot*Ex)/d(GradDens(i,ispin))
C REAL*8  DECDGD(3,nspin): Partial derivative
C                           d(DensTot*Ec)/d(GradDens(i,ispin))
C ********* UNITS ****************************************************
C Lengths in Bohr
C Densities in electrons per Bohr**3
C Energies in Hartrees
C Gradient vectors in cartesian coordinates
C ********* ROUTINES CALLED ******************************************
C EXCHNG, PW92C
C ********************************************************************

      use precision, only : dp

      implicit          none
      INTEGER           IREL, nspin
      real(dp)          Dens(nspin), DECDD(nspin), DECDGD(3,nspin),
     .                  DEXDD(nspin), DEXDGD(3,nspin), GDens(3,nspin)

C Internal variables
      INTEGER
     .  IS, IX
      real(dp)
     .  A, BETA, D(2), DADD, DECUDD, DENMIN, 
     .  DF1DD, DF2DD, DF3DD, DF4DD, DF3DGD, DF4DGD,
     .  DFCDD(2), DFCDGD(3,2), DFDGD, DFXDD(2), DFXDGD(3,2),
     .  DHDD, DHDGD, DKFDD, DKSDD, DPDD, DPDZ, DRSDD, 
     .  DS(2), DSDD, DSDGD, DT, DTDD, DTDGD, DZDD(2), 
     .  EC, ECUNIF, EX, EXUNIF,
     .  F, F1, F2, F3, F4, FC, FX, FOUTHD,
     .  GAMMA, GD(3,2), GDM(2), GDMIN, GDMS, GDMT, GDS, GDT(3),
     .  H, HALF, KF, KFS, KS, PHI, PI, RS, S,
     .  T, THD, THRHLF, TWO, TWOTHD, VCUNIF(2), VXUNIF(2), ZETA
     
      real(dp)          F5, F6, F7, F8, ASINHS
      real(dp)          DF5DD,DF6DD,DF7DD,DF8DD
      real(dp)          DF1DS, DF2DS, DF3DS, DFDS, DF7DGD

C Lower bounds of density and its gradient to avoid divisions by zero
      PARAMETER ( DENMIN = 1.D-12 )
      PARAMETER ( GDMIN  = 1.D-12 )

C Fix some numerical parameters
      PARAMETER ( FOUTHD=4.D0/3.D0, HALF=0.5D0,
     .            THD=1.D0/3.D0, THRHLF=1.5D0,
     .            TWO=2.D0, TWOTHD=2.D0/3.D0 )

C Fix some more numerical constants
      PI = 4.0_dp * ATAN(1.0_dp)
      BETA = 15.75592_dp * 0.004235_dp
      GAMMA = BETA**2 / (2.0_dp * 0.09_dp)

C Translate density and its gradient to new variables
      IF (nspin .EQ. 1) THEN
        D(1) = HALF * Dens(1)
        D(2) = D(1)
        DT = MAX( DENMIN, Dens(1) )
        DO 10 IX = 1,3
          GD(IX,1) = HALF * GDens(IX,1)
          GD(IX,2) = GD(IX,1)
          GDT(IX) = GDens(IX,1)
   10   CONTINUE
      ELSE
        D(1) = Dens(1)
        D(2) = Dens(2)
        DT = MAX( DENMIN, Dens(1)+Dens(2) )
        DO 20 IX = 1,3
          GD(IX,1) = GDens(IX,1)
          GD(IX,2) = GDens(IX,2)
          GDT(IX) = GDens(IX,1) + GDens(IX,2)
   20   CONTINUE
      ENDIF
      GDM(1) = SQRT( GD(1,1)**2 + GD(2,1)**2 + GD(3,1)**2 )
      GDM(2) = SQRT( GD(1,2)**2 + GD(2,2)**2 + GD(3,2)**2 )
      GDMT   = SQRT( GDT(1)**2  + GDT(2)**2  + GDT(3)**2  )
      GDMT = MAX( GDMIN, GDMT )

C Find local correlation energy and potential
      CALL PW92C( 2, D, ECUNIF, VCUNIF )

C Find total correlation energy
      RS = ( 3 / (4*PI*DT) )**THD
      KF = (3 * PI**2 * DT)**THD
      KS = SQRT( 4 * KF / PI )
      S = GDMT / (2 * KF * DT)
      T = GDMT / (2 * KS * DT)
      ZETA = ( D(1) - D(2) ) / DT
      ZETA = MAX( -1.D0+DENMIN, ZETA )
      ZETA = MIN(  1.D0-DENMIN, ZETA )
      PHI = HALF * ( (1+ZETA)**TWOTHD + (1-ZETA)**TWOTHD )
      F1 = ECUNIF / GAMMA / PHI**3
      F2 = EXP(-F1)
      A = BETA / GAMMA / (F2-1)
      F3 = T**2 + A * T**4
      F4 = BETA/GAMMA * F3 / (1 + A*F3)
      F5 = 0.002568D0 + 0.023266D0*RS + 7.389D-6*RS**2
      F6 = 1.0D0 + 8.723D0*RS + 0.472D0*RS**2 + 0.07389D0*RS**3
      F7 = EXP(-100.0D0 * S**2 * PHI**4)
      F8 =  15.75592D0*(0.001667212D0 + F5/F6 -0.004235D0 + 
     .          3.0D0*0.001667212D0/7.0D0)
      H = GAMMA * PHI**3 * LOG( 1 + F4 ) + F8 * T**2 * F7
      FC = ECUNIF + H

C Find correlation energy derivatives
      DRSDD = - THD * RS / DT
      DKFDD =   THD * KF / DT
      DKSDD = HALF * KS * DKFDD / KF
      DZDD(1) =   1 / DT - ZETA / DT
      DZDD(2) = - 1 / DT - ZETA / DT
      DPDZ = HALF * TWOTHD * ( 1/(1+ZETA)**THD - 1/(1-ZETA)**THD )
      DO 40 IS = 1,2
        DECUDD = ( VCUNIF(IS) - ECUNIF ) / DT
        DPDD = DPDZ * DZDD(IS)
        DTDD = - T * ( DPDD/PHI + DKSDD/KS + 1/DT )
        DSDD = - S * ( DPDD/PHI + DKFDD/KF + 1/DT )
        DF1DD = F1 * ( DECUDD/ECUNIF - 3*DPDD/PHI )
        DF2DD = - F2 * DF1DD
        DADD = - A * DF2DD / (F2-1)
        DF3DD = (2*T + 4*A*T**3) * DTDD + DADD * T**4
        DF4DD = F4 * ( DF3DD/F3 - (DADD*F3+A*DF3DD)/(1+A*F3) )
        DF5DD = (0.023266D0 + 2.0D0*7.389D-6*RS)*DRSDD
        DF6DD = (8.723D0 + 2.0D0*0.472D0*RS
     .            + 3.0D0*0.07389D0*RS**2)*DRSDD
        DF7DD = -200.0D0 * S * PHI**4 * DSDD * F7
     .         -100.0D0 * S**2 * 4.0D0* PHI**3 * DPDD * F7
        DF8DD = 15.75592D0 * DF5DD/F6 - 15.75592D0*F5*DF6DD / F6**2
        DHDD = 3 * H * DPDD / PHI
        DHDD = DHDD + GAMMA * PHI**3 * DF4DD / (1+F4)
        DHDD = DHDD + DF8DD * T**2 * F7
        DHDD = DHDD + F8 * 2*T*DTDD *F7
        DHDD = DHDD + F8 * T**2 * DF7DD
        
        DFCDD(IS) = VCUNIF(IS) + H + DT * DHDD
        DO 30 IX = 1,3
          DTDGD = (T / GDMT) * GDT(IX) / GDMT
          DSDGD = (S / GDMT) * GDT(IX) / GDMT
          DF3DGD = DTDGD * ( 2 * T + 4 * A * T**3 )
          DF4DGD = F4 * DF3DGD * ( 1/F3 - A/(1+A*F3) ) 
          DF7DGD = -200.0D0 * S * PHI**4 * DSDGD * F7
          DHDGD = GAMMA * PHI**3 * DF4DGD / (1+F4)
          DHDGD = DHDGD + F8 * 2*T*DTDGD *F7 + F8 * T**2 *DF7DGD
          DFCDGD(IX,IS) = DT * DHDGD
   30   CONTINUE
   40 CONTINUE

C Find exchange energy and potential
      FX = 0
      DO 60 IS = 1,2
        DS(1) = MAX( DENMIN, 2 * D(IS) )
        GDMS = MAX( GDMIN, 2 * GDM(IS) )
        KFS = (3 * PI**2 * DS(1))**THD
        S = GDMS / (2 * KFS * DS(1))
        F4 = SQRT(1.0D0 + (7.7956D0*S)**2)
        ASINHS = LOG(7.7956D0*S + F4)
        F1 = 1.0D0 + 0.19645D0 * S * ASINHS
        F2 = 0.2743D0 - 0.15084D0*EXP(-100.0D0*S*S)
        F3 = 1.0D0 / (F1 + 0.004D0 * S*S*S*S)
        F = (F1 + F2 * S*S ) * F3
     .       
        CALL EXCHNG( IREL, 1, DS, EXUNIF, VXUNIF )
        FX = FX + DS(1) * EXUNIF * F

        DKFDD = THD * KFS / DS(1)
        DSDD = S * ( -DKFDD/KFS - 1/DS(1) )
        DF1DS = 0.19645D0 * ASINHS +
     .    0.19645D0 * S * 7.7956D0 / F4
        DF2DS = 0.15084D0*200.0D0*S*EXP(-100.0D0*S*S)
        DF3DS = - F3*F3 * (DF1DS + 4.0D0*0.004D0 * S*S*S)
        DFDS =  DF1DS * F3 + DF2DS * S*S * F3 + 2.0D0 * S * F2 * F3
     .            + (F1 + F2 * S*S ) * DF3DS   
        DFXDD(IS) = VXUNIF(1) * F + DS(1) * EXUNIF * DFDS * DSDD

        DO 50 IX = 1,3
          GDS = 2 * GD(IX,IS)
          DSDGD = (S / GDMS) * GDS / GDMS
          DFDGD = DFDS * DSDGD
          DFXDGD(IX,IS) = DS(1) * EXUNIF * DFDGD
   50   CONTINUE
   60 CONTINUE
      FX = HALF * FX / DT

C Set output arguments
      EX = FX
      EC = FC
      DO 90 IS = 1,nspin
        DEXDD(IS) = DFXDD(IS)
        DECDD(IS) = DFCDD(IS)
        DO 80 IX = 1,3
          DEXDGD(IX,IS) = DFXDGD(IX,IS)
          DECDGD(IX,IS) = DFCDGD(IX,IS)
   80   CONTINUE
   90 CONTINUE

      END



      SUBROUTINE PW92C( nspin, Dens, EC, VC )

C ********************************************************************
C Implements the Perdew-Wang'92 local correlation (beyond RPA).
C Ref: J.P.Perdew & Y.Wang, PRB, 45, 13244 (1992)
C Written by L.C.Balbas and J.M.Soler. Dec'96.  Version 0.5.
C ********* INPUT ****************************************************
C INTEGER nspin       : Number of spin polarizations (1 or 2)
C REAL*8  Dens(nspin) : Local (spin) density
C ********* OUTPUT ***************************************************
C REAL*8  EC        : Correlation energy density
C REAL*8  VC(nspin) : Correlation (spin) potential
C ********* UNITS ****************************************************
C Densities in electrons per Bohr**3
C Energies in Hartrees
C ********* ROUTINES CALLED ******************************************
C None
C ********************************************************************

      use precision, only : dp

C Next line is nonstandard but may be supressed
      implicit          none

C Argument types and dimensions
      INTEGER           nspin
      real(dp)          Dens(nspin), EC, VC(nspin)

C Internal variable declarations
      INTEGER           IG
      real(dp)          A(0:2), ALPHA1(0:2), B, BETA(0:2,4), C,
     .                  DBDRS, DECDD(2), DECDRS, DECDZ, DENMIN, DFDZ,
     .                  DGDRS(0:2), DCDRS, DRSDD, DTOT, DZDD(2),
     .                  F, FPP0, FOUTHD, G(0:2), HALF, ONE,
     .                  P(0:2), PI, RS, THD, THRHLF, ZETA

C Add tiny numbers to avoid numerical errors
      PARAMETER ( DENMIN = 1.D-12 )
      PARAMETER ( ONE    = 1.D0 + 1.D-12 )

C Fix some numerical constants
      PARAMETER ( FOUTHD=4.D0/3.D0, HALF=0.5D0,
     .            THD=1.D0/3.D0, THRHLF=1.5D0 )

C Parameters from Table I of Perdew & Wang, PRB, 45, 13244 (92)
      DATA P      / 1.00d0,     1.00d0,     1.00d0     /
      DATA A      / 0.031091d0, 0.015545d0, 0.016887d0 /
      DATA ALPHA1 / 0.21370d0,  0.20548d0,  0.11125d0  /
      DATA BETA   / 7.5957d0,  14.1189d0,  10.357d0,
     .              3.5876d0,   6.1977d0,   3.6231d0,
     .              1.6382d0,   3.3662d0,   0.88026d0,
     .              0.49294d0,  0.62517d0,  0.49671d0 /

C Find rs and zeta
      PI = 4 * ATAN(1.D0)
      IF (nspin .EQ. 1) THEN
        DTOT = MAX( DENMIN, Dens(1) )
        ZETA = 0
        RS = ( 3 / (4*PI*DTOT) )**THD
C       Find derivatives dRs/dDens and dZeta/dDens
        DRSDD = (- RS) / DTOT / 3
        DZDD(1) = 0
      ELSE
        DTOT = MAX( DENMIN, Dens(1)+Dens(2) )
        ZETA = ( Dens(1) - Dens(2) ) / DTOT
        RS = ( 3 / (4*PI*DTOT) )**THD
        DRSDD = (- RS) / DTOT / 3
        DZDD(1) =   (ONE - ZETA) / DTOT
        DZDD(2) = - (ONE + ZETA) / DTOT
      ENDIF

C Find eps_c(rs,0)=G(0), eps_c(rs,1)=G(1) and -alpha_c(rs)=G(2)
C using eq.(10) of cited reference (Perdew & Wang, PRB, 45, 13244 (92))
      DO 20 IG = 0,2
        B = BETA(IG,1) * RS**HALF   +
     .      BETA(IG,2) * RS         +
     .      BETA(IG,3) * RS**THRHLF +
     .      BETA(IG,4) * RS**(P(IG)+1)
        DBDRS = BETA(IG,1) * HALF      / RS**HALF +
     .          BETA(IG,2)                         +
     .          BETA(IG,3) * THRHLF    * RS**HALF +
     .          BETA(IG,4) * (P(IG)+1) * RS**P(IG)
        C = 1 + 1 / (2 * A(IG) * B)
        DCDRS = - ( (C-1) * DBDRS / B )
        G(IG) = (- 2) * A(IG) * ( 1 + ALPHA1(IG)*RS ) * LOG(C)
        DGDRS(IG) = (- 2) *A(IG) * ( ALPHA1(IG) * LOG(C) +
     .                            (1+ALPHA1(IG)*RS) * DCDRS / C )
   20 CONTINUE

C Find f''(0) and f(zeta) from eq.(9)
      C = 1 / (2**FOUTHD - 2)
      FPP0 = 8 * C / 9
      F = ( (ONE+ZETA)**FOUTHD + (ONE-ZETA)**FOUTHD - 2 ) * C
      DFDZ = FOUTHD * ( (ONE+ZETA)**THD - (ONE-ZETA)**THD ) * C

C Find eps_c(rs,zeta) from eq.(8)
      EC = G(0) - G(2) * F / FPP0 * (ONE-ZETA**4) +
     .    (G(1)-G(0)) * F * ZETA**4
      DECDRS = DGDRS(0) - DGDRS(2) * F / FPP0 * (ONE-ZETA**4) +
     .        (DGDRS(1)-DGDRS(0)) * F * ZETA**4
      DECDZ = (- G(2)) / FPP0 * ( DFDZ*(ONE-ZETA**4) - F*4*ZETA**3 ) +
     .        (G(1)-G(0)) * ( DFDZ*ZETA**4 + F*4*ZETA**3 )
      
C Find correlation potential
      IF (nspin .EQ. 1) THEN
        DECDD(1) = DECDRS * DRSDD
        VC(1) = EC + DTOT * DECDD(1)
      ELSE
        DECDD(1) = DECDRS * DRSDD + DECDZ * DZDD(1)
        DECDD(2) = DECDRS * DRSDD + DECDZ * DZDD(2)
        VC(1) = EC + DTOT * DECDD(1)
        VC(2) = EC + DTOT * DECDD(2)
      ENDIF

      END



      SUBROUTINE PW92XC( IREL, nspin, Dens, EPSX, EPSC, VX, VC )

C ********************************************************************
C Implements the Perdew-Wang'92 LDA/LSD exchange correlation
C Ref: J.P.Perdew & Y.Wang, PRB, 45, 13244 (1992)
C Written by L.C.Balbas and J.M.Soler. Dec'96. Version 0.5.
C ********* INPUT ****************************************************
C INTEGER IREL        : Relativistic-exchange switch (0=No, 1=Yes)
C INTEGER nspin       : Number of spin polarizations (1 or 2)
C REAL*8  Dens(nspin) : Local (spin) density
C ********* OUTPUT ***************************************************
C REAL*8  EPSX       : Exchange energy density
C REAL*8  EPSC       : Correlation energy density
C REAL*8  VX(nspin)  : Exchange (spin) potential
C REAL*8  VC(nspin)  : Correlation (spin) potential
C ********* UNITS ****************************************************
C Densities in electrons per Bohr**3
C Energies in Hartrees
C ********* ROUTINES CALLED ******************************************
C EXCHNG, PW92C
C ********************************************************************

      use precision, only : dp

      implicit          none
      INTEGER           IREL, nspin
      real(dp)          Dens(nspin), EPSX, EPSC, VC(nspin), VX(nspin)

      CALL EXCHNG( IREL, nspin, Dens, EPSX, VX )
      CALL PW92C( nspin, Dens, EPSC, VC )
      END



      SUBROUTINE PZXC( IREL, NSP, DS, EX, EC, VX, VC, DVXDN, DVCDN )

C *****************************************************************
C  Perdew-Zunger parameterization of Ceperley-Alder exchange and 
C  correlation. Ref: Perdew & Zunger, Phys. Rev. B 23 5075 (1981).
C  Adapted by J.M.Soler from routine velect of Froyen's 
C    pseudopotential generation program. Madrid, Jan'97.
C **** Input *****************************************************
C INTEGER IREL    : relativistic-exchange switch (0=no, 1=yes)
C INTEGER NSP     : spin-polarizations (1=>unpolarized, 2=>polarized)
C REAL*8  DS(NSP) : total (nsp=1) or spin (nsp=2) electron density
C **** Output *****************************************************
C REAL*8  EX            : exchange energy density
C REAL*8  EC            : correlation energy density
C REAL*8  VX(NSP)       : (spin-dependent) exchange potential
C REAL*8  VC(NSP)       : (spin-dependent) correlation potential
C REAL*8  DVXDN(NSP,NSP): Derivative of the exchange potential
C                         respect the charge density, 
C                         Dvx(spin1)/Dn(spin2)
C REAL*8  DVCDN(NSP,NSP): Derivative of the correlation potential
C                         respect the charge density, 
C                         Dvc(spin1)/Dn(spin2)
C **** Units *******************************************************
C Densities in electrons/Bohr**3
C Energies in Hartrees
C *****************************************************************

      use precision, only: dp

      implicit none
      
       integer  :: nsp, irel, isp1, isp2, isp
       real(dp) :: DS(NSP), VX(NSP), VC(NSP), 
     .           DVXDN(NSP,NSP), DVCDN(NSP,NSP)
       real(dp), parameter ::
     $      ZERO=0.D0,ONE=1.D0,PFIVE=.5D0,OPF=1.5D0,PNN=.99D0,
     $      PTHREE=0.3D0,PSEVF=0.75D0,C0504=0.0504D0,
     $      C0254=0.0254D0,C014=0.014D0,C0406=0.0406D0,
     $      C15P9=15.9D0,C0666=0.0666D0,C11P4=11.4D0,
     $      C045=0.045D0,C7P8=7.8D0,C88=0.88D0,C20P59=20.592D0,
     $      C3P52=3.52D0,C0311=0.0311D0,C0014=0.0014D0,
     $      C0538=0.0538D0,C0096=0.0096D0,C096=0.096D0,
     $      C0622=0.0622D0,C004=0.004D0,C0232=0.0232D0,
     $      C1686=0.1686D0,C1P398=1.3981D0,C2611=0.2611D0,
     $      C2846=0.2846D0,C1P053=1.0529D0,C3334=0.3334D0

C    Ceperly-Alder 'ca' constants. Internal energies in Rydbergs.
       real(dp), parameter ::
     $      CON1=1.D0/6, CON2=0.008D0/3, CON3=0.3502D0/3,
     $      CON4=0.0504D0/3, CON5=0.0028D0/3, CON6=0.1925D0/3,
     $      CON7=0.0206D0/3, CON8=9.7867D0/6, CON9=1.0444D0/3,
     $      CON10=7.3703D0/6, CON11=1.3336D0/3

C      X-alpha parameter:
       real(dp), PARAMETER :: ALP = 2.D0 / 3.D0 

C      Other variables converted into parameters by J.M.Soler
       real(dp), parameter ::
     $       TINY = 1.D-6 ,
     $       PI   = 3.14159265358979312_dp,
     $       TWO  = 2.0D0,
     $       HALF = 0.5D0,
     $       TRD  = 1.D0 / 3.D0,
     $       FTRD = 4.D0 / 3.D0,
     $       TFTM = 0.51984209978974638D0,
     $       A0   = 0.52106176119784808D0,
     $       CRS  = 0.620350490899400087D0,
     $       CXP  = (- 3.D0) * ALP / (PI*A0),
     $       CXF  = 1.25992104989487319D0 

       real(dp)  :: d1, d2, d, z, fz, fzp
       real(dp)  :: ex, ec, dfzpdn, rs, vxp, exp_var
       real(dp)  :: beta, sb, alb, vxf, exf, dvxpdn
       real(dp)  :: dvxfdn, sqrs, te, be, ecp, vcp
       real(dp)  :: dtedn, be2, dbedn, dvcpdn, decpdn
       real(dp)  :: ecf, vcf, dvcfdn, decfdn, rslog


C      Find density and polarization
       IF (NSP .EQ. 2) THEN
         D1 = MAX(DS(1),ZERO)
         D2 = MAX(DS(2),ZERO)
         D = D1 + D2
         IF (D .LE. ZERO) THEN
           EX = ZERO
           EC = ZERO
           VX(1) = ZERO
           VX(2) = ZERO
           VC(1) = ZERO
           VC(2) = ZERO
           RETURN
         ENDIF
c
c        Robustness enhancement by Jose Soler (August 2002)
c
         Z = (D1 - D2) / D
         IF (Z .LE. -ONE) THEN
           FZ = (TWO**FTRD-TWO)/TFTM
           FZP = -FTRD*TWO**TRD/TFTM
           DFZPDN = FTRD*TRD*TWO**(-ALP)/TFTM
         ELSEIF (Z .GE. ONE) THEN
           FZ = (TWO**FTRD-TWO)/TFTM
           FZP = FTRD*TWO**TRD/TFTM
           DFZPDN = FTRD*TRD*TWO**(-ALP)/TFTM
         ELSE
           FZ = ((ONE+Z)**FTRD+(ONE-Z)**FTRD-TWO)/TFTM
           FZP = FTRD*((ONE+Z)**TRD-(ONE-Z)**TRD)/TFTM 
           DFZPDN = FTRD*TRD*((ONE+Z)**(-ALP) + (ONE-Z)**(-ALP))/TFTM
         ENDIF
       ELSE
         D = DS(1)
         IF (D .LE. ZERO) THEN
           EX = ZERO
           EC = ZERO
           VX(1) = ZERO
           VC(1) = ZERO
           RETURN
         ENDIF
         Z = ZERO
         FZ = ZERO
         FZP = ZERO
       ENDIF
       RS = CRS / D**TRD

C      Exchange
       VXP = CXP / RS
       EXP_VAR = 0.75D0 * VXP
       IF (IREL .EQ. 1) THEN
         BETA = C014/RS
         IF (BETA .LT. TINY) THEN
           SB = ONE + HALF*BETA**2
           ALB = BETA
         ELSE
           SB = SQRT(1+BETA*BETA)
           ALB = LOG(BETA+SB)
         ENDIF
         VXP = VXP * (-PFIVE + OPF * ALB / (BETA*SB))
         EXP_VAR = EXP_VAR *(ONE-OPF*((BETA*SB-ALB)/BETA**2)**2) 
       ENDIF
       VXF = CXF * VXP
       EXF = CXF * EXP_VAR
       DVXPDN = TRD * VXP / D
       DVXFDN = TRD * VXF / D

C      Correlation 
       IF (RS .GT. ONE) THEN  
         SQRS=SQRT(RS)
         TE = ONE+CON10*SQRS+CON11*RS
         BE = ONE+C1P053*SQRS+C3334*RS
         ECP = -(C2846/BE)
         VCP = ECP*TE/BE
         DTEDN = ((CON10 * SQRS *HALF) + CON11 * RS)*(-TRD/D)
         BE2 = BE * BE
         DBEDN = ((C1P053 * SQRS *HALF) + C3334 * RS)*(-TRD/D)
         DVCPDN = -(C2846/BE2)*(DTEDN - 2.0D0 * TE * DBEDN/BE)
         DECPDN = (C2846/BE2)*DBEDN
         TE = ONE+CON8*SQRS+CON9*RS
         BE = ONE+C1P398*SQRS+C2611*RS
         ECF = -(C1686/BE)
         VCF = ECF*TE/BE
         DTEDN = ((CON8 * SQRS * HALF) + CON9 * RS)*(-TRD/D)
         BE2 = BE * BE
         DBEDN = ((C1P398 * SQRS * HALF) + C2611 * RS)*(-TRD/D)
         DVCFDN = -(C1686/BE2)*(DTEDN - 2.0D0 * TE * DBEDN/BE)
         DECFDN = (C1686/BE2)*DBEDN
       ELSE
         RSLOG=LOG(RS)
         ECP=(C0622+C004*RS)*RSLOG-C096-C0232*RS
         VCP=(C0622+CON2*RS)*RSLOG-CON3-CON4*RS
         DVCPDN = (CON2*RS*RSLOG + (CON2-CON4)*RS + C0622)*(-TRD/D)
         DECPDN = (C004*RS*RSLOG + (C004-C0232)*RS + C0622)*(-TRD/D)
         ECF=(C0311+C0014*RS)*RSLOG-C0538-C0096*RS
         VCF=(C0311+CON5*RS)*RSLOG-CON6-CON7*RS
         DVCFDN = (CON5*RS*RSLOG + (CON5-CON7)*RS + C0311)*(-TRD/D)
         DECFDN = (C0014*RS*RSLOG + (C0014-C0096)*RS + C0311)*(-TRD/D)
       ENDIF

       ISP1 = 1
       ISP2 = 2

C      Find up and down potentials
       IF (NSP .EQ. 2) THEN
         EX    = EXP_VAR + FZ*(EXF-EXP_VAR)
         EC    = ECP + FZ*(ECF-ECP)
         VX(1) = VXP + FZ*(VXF-VXP) + (ONE-Z)*FZP*(EXF-EXP_VAR)
         VX(2) = VXP + FZ*(VXF-VXP) - (ONE+Z)*FZP*(EXF-EXP_VAR)
         VC(1) = VCP + FZ*(VCF-VCP) + (ONE-Z)*FZP*(ECF-ECP)
         VC(2) = VCP + FZ*(VCF-VCP) - (ONE+Z)*FZP*(ECF-ECP)

C        Derivatives of exchange potential respect the density

         DVXDN(ISP1,ISP1) =
     .             DVXPDN
     .              +  FZP*(VXF-VXP-EXF+EXP_VAR)*( 2.D0*D2/(D*D) )
     .              +  FZ*(DVXFDN-DVXPDN)+(1-Z)*FZP*(VXF-VXP)/(4.D0*D)
     .              +  (1-Z)*DFZPDN*(EXF-EXP_VAR)*( 2.D0*D2/(D*D) )
         DVXDN(ISP1,ISP2) =
     .                 DVXPDN
     .              +  FZP*(VXF-VXP-EXF+EXP_VAR)*(-2.D0*D1/(D*D) )
     .              +  FZ*(DVXFDN-DVXPDN)+(1-Z)*FZP*(VXF-VXP)/(4.D0*D)
     .              +  (1-Z)*DFZPDN*(EXF-EXP_VAR)*( -2.D0*D1/(D*D) )
         DVXDN(ISP2,ISP1) =
     .                 DVXPDN
     .              +  FZP*(VXF-VXP-EXF+EXP_VAR)*( 2.D0*D2/(D*D) )
     .              +  FZ*(DVXFDN-DVXPDN)-(1+Z)*FZP*(VXF-VXP)/(4.D0*D)
     .              -  (1+Z)*DFZPDN*(EXF-EXP_VAR)*( 2.D0*D2/(D*D) )
         DVXDN(ISP2,ISP2) =
     .                 DVXPDN
     .              +  FZP*(VXF-VXP-EXF+EXP_VAR)*(-2.D0*D1/(D*D) )
     .              +  FZ*(DVXFDN-DVXPDN)-(1+Z)*FZP*(VXF-VXP)/(4.D0*D)
     .              -  (1+Z)*DFZPDN*(EXF-EXP_VAR)*( -2.D0*D1/(D*D) )

C        Derivatives of correlation potential respect the density

         DVCDN(ISP1,ISP1) =
     .                DVCPDN
     .              + FZP*(VCF-VCP-ECF+ECP)*( 2.D0*D2/(D*D) )
     .              + FZ*(DVCFDN-DVCPDN)+ (1-Z)*FZP*(DECFDN-DECPDN)
     .              + (1-Z)*DFZPDN*(ECF-ECP)*( 2.D0*D2/(D*D) )
         DVCDN(ISP1,ISP2) =
     .                DVCPDN
     .              + FZP*(VCF-VCP-ECF+ECP)*(-2.D0*D1/(D*D) )
     .              + FZ*(DVCFDN-DVCPDN)+ (1-Z)*FZP*(DECFDN-DECPDN)
     .              + (1-Z)*DFZPDN*(ECF-ECP)*( -2.D0*D1/(D*D) )
         DVCDN(ISP2,ISP1) =
     .                DVCPDN
     .              + FZP*(VCF-VCP-ECF+ECP)*( 2.D0*D2/(D*D) )
     .              + FZ*(DVCFDN-DVCPDN)- (1+Z)*FZP*(DECFDN-DECPDN)
     .              - (1+Z)*DFZPDN*(ECF-ECP)*( 2.D0*D2/(D*D) )
         DVCDN(ISP2,ISP2) =
     .                DVCPDN
     .              + FZP*(VCF-VCP-ECF+ECP)*(-2.D0*D1/(D*D) )
     .              + FZ*(DVCFDN-DVCPDN)- (1+Z)*FZP*(DECFDN-DECPDN)
     .              - (1+Z)*DFZPDN*(ECF-ECP)*( -2.D0*D1/(D*D) )

       ELSE
         EX    = EXP_VAR
         EC    = ECP
         VX(1) = VXP
         VC(1) = VCP
         DVXDN(1,1) = DVXPDN
         DVCDN(1,1) = DVCPDN
       ENDIF

C      Change from Rydbergs to Hartrees
       EX = HALF * EX
       EC = HALF * EC
       DO 10 ISP = 1,NSP
         VX(ISP) = HALF * VX(ISP)
         VC(ISP) = HALF * VC(ISP)
         DO 5 ISP2 = 1,NSP
           DVXDN(ISP,ISP2) = HALF * DVXDN(ISP,ISP2)
           DVCDN(ISP,ISP2) = HALF * DVCDN(ISP,ISP2)
    5    CONTINUE
   10  CONTINUE
      END

       subroutine blypxc(nspin,dens,gdens,EX,EC,
     .                   dEXdd,dECdd,dEXdgd,dECdgd) 
c ***************************************************************
c Implements Becke gradient exchange functional (A.D. 
c Becke, Phys. Rev. A 38, 3098 (1988)) and Lee, Yang, Parr
c correlation functional (C. Lee, W. Yang, R.G. Parr, Phys. Rev. B
c 37, 785 (1988)), as modificated by Miehlich,Savin,Stoll and Preuss,
c Chem. Phys. Lett. 157,200 (1989). See also Johnson, Gill and Pople,
c J. Chem. Phys. 98, 5612 (1993). Some errors were detected in this
c last paper, so not all of the expressions correspond exactly to those
c implemented here.
c Written by Maider Machado. July 1998.
c **************** INPUT ******************************************** 
c integer nspin          : Number of spin polarizations (1 or 2)
c real*8  dens(nspin)    : Total electron density (if nspin=1) or
c                           spin electron density (if nspin=2)
c real*8  gdens(3,nspin) : Total or spin density gradient
c ******** OUTPUT *****************************************************
c real*8  ex             : Exchange energy density
c real*8  ec             : Correlation energy density
c real*8  dexdd(nspin)   : Partial derivative
c                           d(DensTot*Ex)/dDens(ispin),
c                           where DensTot = Sum_ispin( Dens(ispin) )
c                          For a constant density, this is the
c                          exchange potential
c real*8  decdd(nspin)   : Partial derivative
c                           d(DensTot*Ec)/dDens(ispin),
c                           where DensTot = Sum_ispin( Dens(ispin) )
c                          For a constant density, this is the
c                          correlation potential
c real*8  dexdgd(3,nspin): Partial derivative
c                           d(DensTot*Ex)/d(GradDens(i,ispin))
c real*8  decdgd(3,nspin): Partial derivative
c                           d(DensTot*Ec)/d(GradDens(i,ispin))
c ********* UNITS ****************************************************
c Lengths in Bohr
c Densities in electrons per Bohr**3
c Energies in Hartrees
c Gradient vectors in cartesian coordinates
c ********************************************************************
 
      use precision, only : dp

      implicit none

      integer nspin
      real(dp)   dens(nspin), gdens(3,nspin), EX, EC,
     .           dEXdd(nspin), dECdd(nspin), dEXdgd(3,nspin),
     .           dECdgd(3,nspin)

c Internal variables
      integer is,ix
      real(dp)   pi, beta, thd, tthd, thrhlf, half, fothd,
     .           d(2),gd(3,2),dmin, ash,gdm(2),denmin,dt, 
     .           g(2),x(2),a,b,c,dd,onzthd,gdmin,     
     .           ga, gb, gc,becke,dbecgd(3,2),
     .           dgdx(2), dgdxa, dgdxb, dgdxc,dgdxd,dbecdd(2),
     .           den,omega, domega, delta, ddelta,cf,
     .           gam11, gam12, gam22, LYPa, LYPb1,
     .           LYPb2,dLYP11,dLYP12,dLYP22,LYP,
     .           dd1g11,dd1g12,dd1g22,dd2g12,dd2g11,dd2g22,
     .           dLYPdd(2),dg11dd(3,2),dg22dd(3,2),
     .           dLYPgd(3,2)
  
c Lower bounds of density and its gradient to avoid divisions by zero
      parameter ( denmin=1.d-8 )
      parameter (gdmin=1.d-8)
      parameter (dmin=1.d-5)

c Fix some numerical parameters 
      parameter ( thd = 1.d0/3.d0, tthd=2.d0/3.d0 )
      parameter ( thrhlf=1.5d0, half=0.5d0,
     .            fothd=4.d0/3.d0, onzthd=11.d0/3.d0)

c Empirical parameter for Becke exchange functional (a.u.)
      parameter(beta= 0.0042d0) 

c Constants for LYP functional (a.u.) 
      parameter(a=0.04918d0, b=0.132d0, c=0.2533d0, dd=0.349d0)

       pi= 4*atan(1.d0)
       

c Translate density and its gradient to new variables
      if (nspin .eq. 1) then
        d(1) = half * dens(1)
        d(1) = max(denmin,d(1))
        d(2) = d(1)
        dt = max( denmin, dens(1) )
        do ix = 1,3
          gd(ix,1) = half * gdens(ix,1)    
          gd(ix,2) = gd(ix,1)
        enddo 
      else
        d(1) = dens(1)
        d(2) = dens(2)
        do is=1,2
         d(is) = max (denmin,d(is))
        enddo
        dt = max( denmin, dens(1)+dens(2) )  
        do ix = 1,3
          gd(ix,1) = gdens(ix,1)
          gd(ix,2) = gdens(ix,2)
        enddo
      endif

      gdm(1) = sqrt( gd(1,1)**2 + gd(2,1)**2 + gd(3,1)**2 )
      gdm(2) = sqrt( gd(1,2)**2 + gd(2,2)**2 + gd(3,2)**2 )
 
      do is=1,2
      gdm(is)= max(gdm(is),gdmin)
      enddo

c Find Becke exchange energy
       ga = -thrhlf*(3.d0/4.d0/pi)**thd
      do is=1,2
       if(d(is).lt.dmin) then
        g(is)=ga
       else
        x(is) = gdm(is)/d(is)**fothd
        gb = beta*x(is)**2
        ash=log(x(is)+sqrt(x(is)**2+1)) 
        gc = 1+6*beta*x(is)*ash        
        g(is) = ga-gb/gc
       endif
      enddo

c   Density of energy 
      becke=(g(1)*d(1)**fothd+g(2)*d(2)**fothd)/dt

      
c Exchange energy derivatives
       do is=1,2
        if(d(is).lt.dmin)then
         dbecdd(is)=0.
         do ix=1,3
          dbecgd(ix,is)=0.
         enddo
        else
        dgdxa=6*beta**2*x(is)**2
        ash=log(x(is)+sqrt(x(is)**2+1))
        dgdxb=x(is)/sqrt(x(is)**2+1)-ash
        dgdxc=-2*beta*x(is)
        dgdxd=(1+6*beta*x(is)*ash)**2
        dgdx(is)=(dgdxa*dgdxb+dgdxc)/dgdxd
        dbecdd(is)=fothd*d(is)**thd*(g(is)-x(is)*dgdx(is))
        do ix=1,3
         dbecgd(ix,is)=d(is)**(-fothd)*dgdx(is)*gd(ix,is)/x(is)
        enddo 
        endif
       enddo

c  Lee-Yang-Parr correlation energy
      den=1+dd*dt**(-thd)
      omega=dt**(-onzthd)*exp(-c*dt**(-thd))/den
      delta=c*dt**(-thd)+dd*dt**(-thd)/den
      cf=3.*(3*pi**2)**tthd/10.
      gam11=gdm(1)**2
      gam12=gd(1,1)*gd(1,2)+gd(2,1)*gd(2,2)+gd(3,1)*gd(3,2)
      gam22=gdm(2)**2
      LYPa=-4*a*d(1)*d(2)/(den*dt)
      LYPb1=2**onzthd*cf*a*b*omega*d(1)*d(2)
      LYPb2=d(1)**(8./3.)+d(2)**(8./3.)
      dLYP11=-a*b*omega*(d(1)*d(2)/9.*(1.-3.*delta-(delta-11.)
     .*d(1)/dt)-d(2)**2)
      dLYP12=-a*b*omega*(d(1)*d(2)/9.*(47.-7.*delta)
     .-fothd*dt**2)
      dLYP22=-a*b*omega*(d(1)*d(2)/9.*(1.-3.*delta-(delta-11.)*
     .d(2)/dt)-d(1)**2)

c    Density of energy
      LYP=(LYPa-LYPb1*LYPb2+dLYP11*gam11+dLYP12*gam12
     .+dLYP22*gam22)/dt

c   Correlation energy derivatives
       domega=-thd*dt**(-fothd)*omega*(11.*dt**thd-c-dd/den)
       ddelta=thd*(dd**2*dt**(-5./3.)/den**2-delta/dt)

c   Second derivatives with respect to the density
       dd1g11=domega/omega*dLYP11-a*b*omega*(d(2)/9.*
     . (1.-3.*delta-2*(delta-11.)*d(1)/dt)-d(1)*d(2)/9.*
     . ((3.+d(1)/dt)*ddelta-(delta-11.)*d(1)/dt**2))

       dd1g12=domega/omega*dLYP12-a*b*omega*(d(2)/9.*
     . (47.-7.*delta)-7./9.*d(1)*d(2)*ddelta-8./3.*dt)

      dd1g22=domega/omega*dLYP22-a*b*omega*(1./9.*d(2)
     . *(1.-3.*delta-(delta-11.)*d(2)/dt)-d(1)*d(2)/9.*
     . ((3.+d(2)/dt)*ddelta-(delta-11.)*d(2)/dt**2)-2*d(1))

       
      dd2g22=domega/omega*dLYP22-a*b*omega*(d(1)/9.*
     . (1.-3.*delta-2*(delta-11.)*d(2)/dt)-d(1)*d(2)/9.*
     . ((3+d(2)/dt)*ddelta-(delta-11.)*d(2)/dt**2))
      
 
      dd2g12=domega/omega*dLYP12-a*b*omega*(d(1)/9.*
     . (47.-7.*delta)-7./9.*d(1)*d(2)*ddelta-8./3.*dt)
      
      dd2g11=domega/omega*dLYP11-a*b*omega*(1./9.*d(1)
     . *(1.-3.*delta-(delta-11.)*d(1)/dt)-d(1)*d(2)/9.*
     . ((3.+d(1)/dt)*ddelta-(delta-11.)*d(1)/dt**2)-2*d(2))


        dLYPdd(1)=-4*a/den*d(1)*d(2)/dt*
     . (thd*dd*dt**(-fothd)/den
     . +1./d(1)-1./dt)-2**onzthd*cf*a*b*(domega*d(1)*d(2)*
     . (d(1)**(8./3.)+d(2)**(8./3.))+omega*d(2)*(onzthd*
     . d(1)**(8./3.)+d(2)**(8./3.)))+dd1g11*gam11+
     . dd1g12*gam12+dd1g22*gam22


       dLYPdd(2)=-4*a/den*d(1)*d(2)/dt*(thd*dd*dt**(-fothd)/den
     . +1./d(2)-1./dt)-2**onzthd*cf*a*b*(domega*d(1)*d(2)*
     . (d(1)**(8./3.)+d(2)**(8./3.))+omega*d(1)*(onzthd*
     . d(2)**(8./3.)+d(1)**(8./3.)))+dd2g22*gam22+
     . dd2g12*gam12+dd2g11*gam11


c second derivatives with respect to the density gradient

        do is=1,2
          do ix=1,3
           dg11dd(ix,is)=2*gd(ix,is)
           dg22dd(ix,is)=2*gd(ix,is)
          enddo
        enddo
        do ix=1,3
          dLYPgd(ix,1)=dLYP11*dg11dd(ix,1)+dLYP12*gd(ix,2)
          dLYPgd(ix,2)=dLYP22*dg22dd(ix,2)+dLYP12*gd(ix,1)
        enddo


       EX=becke
       EC=LYP
       do is=1,nspin
        dEXdd(is)=dbecdd(is)
        dECdd(is)=dLYPdd(is)
        do ix=1,3
         dEXdgd(ix,is)=dbecgd(ix,is)
         dECdgd(ix,is)=dLYPgd(ix,is)
        enddo
       enddo
       end 

      SUBROUTINE RPBEXC( IREL, nspin, Dens, GDens,
     .                   EX, EC, DEXDD, DECDD, DEXDGD, DECDGD )

C *********************************************************************
C Implements Hammer's RPBE Generalized-Gradient-Approximation (GGA).
C A revision of PBE (Perdew-Burke-Ernzerhof) 
C Ref: Hammer, Hansen & Norskov, PRB 59, 7413 (1999) and
C J.P.Perdew, K.Burke & M.Ernzerhof, PRL 77, 3865 (1996)
C
C Written by M.V. Fernandez-Serra. March 2004. On the PBE routine of
C L.C.Balbas and J.M.Soler. December 1996. Version 0.5.
C ******** INPUT ******************************************************
C INTEGER IREL           : Relativistic-exchange switch (0=No, 1=Yes)
C INTEGER nspin          : Number of spin polarizations (1 or 2)
C REAL*8  Dens(nspin)    : Total electron density (if nspin=1) or
C                           spin electron density (if nspin=2)
C REAL*8  GDens(3,nspin) : Total or spin density gradient
C ******** OUTPUT *****************************************************
C REAL*8  EX             : Exchange energy density
C REAL*8  EC             : Correlation energy density
C REAL*8  DEXDD(nspin)   : Partial derivative
C                           d(DensTot*Ex)/dDens(ispin),
C                           where DensTot = Sum_ispin( Dens(ispin) )
C                          For a constant density, this is the
C                          exchange potential
C REAL*8  DECDD(nspin)   : Partial derivative
C                           d(DensTot*Ec)/dDens(ispin),
C                           where DensTot = Sum_ispin( Dens(ispin) )
C                          For a constant density, this is the
C                          correlation potential
C REAL*8  DEXDGD(3,nspin): Partial derivative
C                           d(DensTot*Ex)/d(GradDens(i,ispin))
C REAL*8  DECDGD(3,nspin): Partial derivative
C                           d(DensTot*Ec)/d(GradDens(i,ispin))
C ********* UNITS ****************************************************
C Lengths in Bohr
C Densities in electrons per Bohr**3
C Energies in Hartrees
C Gradient vectors in cartesian coordinates
C ********* ROUTINES CALLED ******************************************
C EXCHNG, PW92C
C ********************************************************************

      use precision, only : dp

      implicit          none
      INTEGER           IREL, nspin
      real(dp)          Dens(nspin), DECDD(nspin), DECDGD(3,nspin),
     .                  DEXDD(nspin), DEXDGD(3,nspin), GDens(3,nspin)

C Internal variables
      INTEGER
     .  IS, IX

      real(dp)
     .  A, BETA, D(2), DADD, DECUDD, DENMIN, 
     .  DF1DD, DF2DD, DF3DD, DF4DD, DF1DGD, DF3DGD, DF4DGD,
     .  DFCDD(2), DFCDGD(3,2), DFDD, DFDGD, DFXDD(2), DFXDGD(3,2),
     .  DHDD, DHDGD, DKFDD, DKSDD, DPDD, DPDZ, DRSDD, 
     .  DS(2), DSDD, DSDGD, DT, DTDD, DTDGD, DZDD(2), 
     .  EC, ECUNIF, EX, EXUNIF,
     .  F, F1, F2, F3, F4, FC, FX, FOUTHD,
     .  GAMMA, GD(3,2), GDM(2), GDMIN, GDMS, GDMT, GDS, GDT(3),
     .  H, HALF, KAPPA, KF, KFS, KS, MU, PHI, PI, RS, S,
     .  T, THD, THRHLF, TWO, TWOTHD, VCUNIF(2), VXUNIF(2), ZETA

C Lower bounds of density and its gradient to avoid divisions by zero
      PARAMETER ( DENMIN = 1.D-12 )
      PARAMETER ( GDMIN  = 1.D-12 )

C Fix some numerical parameters
      PARAMETER ( FOUTHD=4.D0/3.D0, HALF=0.5D0,
     .            THD=1.D0/3.D0, THRHLF=1.5D0,
     .            TWO=2.D0, TWOTHD=2.D0/3.D0 )

C Fix some more numerical constants
      PI = 4 * ATAN(1.D0)
      BETA = 0.066725D0
      GAMMA = (1 - LOG(TWO)) / PI**2
      MU = BETA * PI**2 / 3
      KAPPA = 0.804D0

C Translate density and its gradient to new variables
      IF (nspin .EQ. 1) THEN
        D(1) = HALF * Dens(1)
        D(2) = D(1)
        DT = MAX( DENMIN, Dens(1) )
        DO 10 IX = 1,3
          GD(IX,1) = HALF * GDens(IX,1)
          GD(IX,2) = GD(IX,1)
          GDT(IX) = GDens(IX,1)
   10   CONTINUE
      ELSE
        D(1) = Dens(1)
        D(2) = Dens(2)
        DT = MAX( DENMIN, Dens(1)+Dens(2) )
        DO 20 IX = 1,3
          GD(IX,1) = GDens(IX,1)
          GD(IX,2) = GDens(IX,2)
          GDT(IX) = GDens(IX,1) + GDens(IX,2)
   20   CONTINUE
      ENDIF
      GDM(1) = SQRT( GD(1,1)**2 + GD(2,1)**2 + GD(3,1)**2 )
      GDM(2) = SQRT( GD(1,2)**2 + GD(2,2)**2 + GD(3,2)**2 )
      GDMT   = SQRT( GDT(1)**2  + GDT(2)**2  + GDT(3)**2  )
      GDMT = MAX( GDMIN, GDMT )

C Find local correlation energy and potential
      CALL PW92C( 2, D, ECUNIF, VCUNIF )

C Find total correlation energy
      RS = ( 3 / (4*PI*DT) )**THD
      KF = (3 * PI**2 * DT)**THD
      KS = SQRT( 4 * KF / PI )
      ZETA = ( D(1) - D(2) ) / DT
      ZETA = MAX( -1.D0+DENMIN, ZETA )
      ZETA = MIN(  1.D0-DENMIN, ZETA )
      PHI = HALF * ( (1+ZETA)**TWOTHD + (1-ZETA)**TWOTHD )
      T = GDMT / (2 * PHI * KS * DT)
      F1 = ECUNIF / GAMMA / PHI**3
      F2 = EXP(-F1)
      A = BETA / GAMMA / (F2-1)
      F3 = T**2 + A * T**4
      F4 = BETA/GAMMA * F3 / (1 + A*F3)
      H = GAMMA * PHI**3 * LOG( 1 + F4 )
      FC = ECUNIF + H

C Find correlation energy derivatives
      DRSDD = - (THD * RS / DT)
      DKFDD =   THD * KF / DT
      DKSDD = HALF * KS * DKFDD / KF
      DZDD(1) =   1 / DT - ZETA / DT
      DZDD(2) = - (1 / DT) - ZETA / DT
      DPDZ = HALF * TWOTHD * ( 1/(1+ZETA)**THD - 1/(1-ZETA)**THD )
      DO 40 IS = 1,2
        DECUDD = ( VCUNIF(IS) - ECUNIF ) / DT
        DPDD = DPDZ * DZDD(IS)
        DTDD = (- T) * ( DPDD/PHI + DKSDD/KS + 1/DT )
        DF1DD = F1 * ( DECUDD/ECUNIF - 3*DPDD/PHI )
        DF2DD = (- F2) * DF1DD
        DADD = (- A) * DF2DD / (F2-1)
        DF3DD = (2*T + 4*A*T**3) * DTDD + DADD * T**4
        DF4DD = F4 * ( DF3DD/F3 - (DADD*F3+A*DF3DD)/(1+A*F3) )
        DHDD = 3 * H * DPDD / PHI
        DHDD = DHDD + GAMMA * PHI**3 * DF4DD / (1+F4)
        DFCDD(IS) = VCUNIF(IS) + H + DT * DHDD

        DO 30 IX = 1,3
          DTDGD = (T / GDMT) * GDT(IX) / GDMT
          DF3DGD = DTDGD * ( 2 * T + 4 * A * T**3 )
          DF4DGD = F4 * DF3DGD * ( 1/F3 - A/(1+A*F3) ) 
          DHDGD = GAMMA * PHI**3 * DF4DGD / (1+F4)
          DFCDGD(IX,IS) = DT * DHDGD
   30   CONTINUE
   40 CONTINUE

C Find exchange energy and potential
      FX = 0
      DO 60 IS = 1,2
        DS(IS)   = MAX( DENMIN, 2 * D(IS) )
        GDMS = MAX( GDMIN, 2 * GDM(IS) )
        KFS = (3 * PI**2 * DS(IS))**THD
        S = GDMS / (2 * KFS * DS(IS))
cea Hammer's RPBE (Hammer, Hansen & Norskov PRB 59 7413 (99)
cea     F1 = DEXP( - MU * S**2 / KAPPA)
cea     F = 1 + KAPPA * (1 - F1)
cea Following is standard PBE
cea     F1 = 1 + MU * S**2 / KAPPA
cea     F = 1 + KAPPA - KAPPA / F1
cea (If revPBE Zhang & Yang, PRL 80,890(1998),change PBE's KAPPA to 1.245)
        F1 = DEXP( - MU * S**2 / KAPPA)
        F = 1 + KAPPA * (1 - F1)
 
c       Note nspin=1 in call to exchng...
 
        CALL EXCHNG( IREL, 1, DS(IS), EXUNIF, VXUNIF(IS) )
        FX = FX + DS(IS) * EXUNIF * F

cMVFS   The derivatives of F  also need to be changed for Hammer's RPBE.
cMVFS   DF1DD = 2 * F1 * DSDD  * ( - MU * S / KAPPA)
cMVFS   DF1DGD= 2 * F1 * DSDGD * ( - MU * S / KAPPA)
cMVFS   DFDD  = -1 * KAPPA * DF1DD
cMVFS   DFDGD = -1 * KAPPA * DFDGD

        DKFDD = THD * KFS / DS(IS)
        DSDD = S * ( -(DKFDD/KFS) - 1/DS(IS) )
c       DF1DD = 2 * (F1-1) * DSDD / S
c       DFDD = KAPPA * DF1DD / F1**2
        DF1DD = 2* F1 * DSDD * ( - MU * S / KAPPA)
        DFDD = -1 * KAPPA * DF1DD
        DFXDD(IS) = VXUNIF(IS) * F + DS(IS) * EXUNIF * DFDD

        DO 50 IX = 1,3
          GDS = 2 * GD(IX,IS)
          DSDGD = (S / GDMS) * GDS / GDMS
c         DF1DGD = 2 * MU * S * DSDGD / KAPPA
c         DFDGD = KAPPA * DF1DGD / F1**2
          DF1DGD =2*F1 * DSDGD * ( - MU * S / KAPPA)
          DFDGD = -1 * KAPPA * DF1DGD
          DFXDGD(IX,IS) = DS(IS) * EXUNIF * DFDGD
   50   CONTINUE
   60 CONTINUE
      FX = HALF * FX / DT

C Set output arguments
      EX = FX
      EC = FC
      DO 90 IS = 1,nspin
        DEXDD(IS) = DFXDD(IS)
        DECDD(IS) = DFCDD(IS)
        DO 80 IX = 1,3
          DEXDGD(IX,IS) = DFXDGD(IX,IS)
          DECDGD(IX,IS) = DFCDGD(IX,IS)
   80   CONTINUE
   90 CONTINUE

      END
      SUBROUTINE WCXC( IREL, nspin, Dens, GDens,
     .                  EX, EC, DEXDD, DECDD, DEXDGD, DECDGD )

C *********************************************************************
C Implements Wu-Cohen Generalized-Gradient-Approximation.
C Ref: Z. Wu and R. E. Cohen PRB 73, 235116 (2006)
C Written by Marivi Fernandez-Serra, with contributions by
C Julian Gale and Alberto Garcia,
C over the PBEXC subroutine of L.C.Balbas and J.M.Soler.
C September, 2006.
C ******** INPUT ******************************************************
C INTEGER IREL           : Relativistic-exchange switch (0=No, 1=Yes)
C INTEGER nspin          : Number of spin polarizations (1 or 2)
C REAL*8  Dens(nspin)    : Total electron density (if nspin=1) or
C                           spin electron density (if nspin=2)
C REAL*8  GDens(3,nspin) : Total or spin density gradient
C ******** OUTPUT *****************************************************
C REAL*8  EX             : Exchange energy density
C REAL*8  EC             : Correlation energy density
C REAL*8  DEXDD(nspin)   : Partial derivative
C                           d(DensTot*Ex)/dDens(ispin),
C                           where DensTot = Sum_ispin( Dens(ispin) )
C                          For a constant density, this is the
C                          exchange potential
C REAL*8  DECDD(nspin)   : Partial derivative
C                           d(DensTot*Ec)/dDens(ispin),
C                           where DensTot = Sum_ispin( Dens(ispin) )
C                          For a constant density, this is the
C                          correlation potential
C REAL*8  DEXDGD(3,nspin): Partial derivative
C                           d(DensTot*Ex)/d(GradDens(i,ispin))
C REAL*8  DECDGD(3,nspin): Partial derivative
C                           d(DensTot*Ec)/d(GradDens(i,ispin))
C ********* UNITS ****************************************************
C Lengths in Bohr
C Densities in electrons per Bohr**3
C Energies in Hartrees
C Gradient vectors in cartesian coordinates
C ********* ROUTINES CALLED ******************************************
C EXCHNG, PW92C
C ********************************************************************

      use precision, only : dp

      implicit          none
      INTEGER           IREL, nspin
      real(dp)          Dens(nspin), DECDD(nspin), DECDGD(3,nspin),
     .                  DEXDD(nspin), DEXDGD(3,nspin), GDens(3,nspin)

C Internal variables
      INTEGER
     .  IS, IX

      real(dp)
     .  A, BETA, D(2), DADD, DECUDD, DENMIN, 
     .  DF1DD, DF2DD, DF3DD, DF4DD, DF1DGD, DF3DGD, DF4DGD,
     .  DFCDD(2), DFCDGD(3,2), DFDD, DFDGD, DFXDD(2), DFXDGD(3,2),
     .  DHDD, DHDGD, DKFDD, DKSDD, DPDD, DPDZ, DRSDD, 
     .  DS(2), DSDD, DSDGD, DT, DTDD, DTDGD, DZDD(2), 
     .  XWC, DXWCDS, CWC,
     .  EC, ECUNIF, EX, EXUNIF,
     .  F, F1, F2, F3, F4, FC, FX, FOUTHD,
     .  GAMMA, GD(3,2), GDM(2), GDMIN, GDMS, GDMT, GDS, GDT(3),
     .  H, HALF, KAPPA, KF, KFS, KS, MU, PHI, PI, RS, S,
     .  TEN81, 
     .  T, THD, THRHLF, TWO, TWOTHD, VCUNIF(2), VXUNIF(2), ZETA

C Lower bounds of density and its gradient to avoid divisions by zero
      PARAMETER ( DENMIN = 1.D-12 )
      PARAMETER ( GDMIN  = 1.D-12 )

C Fix some numerical parameters
      PARAMETER ( FOUTHD=4.D0/3.D0, HALF=0.5D0,
     .            THD=1.D0/3.D0, THRHLF=1.5D0,
     .            TWO=2.D0, TWOTHD=2.D0/3.D0 )
      PARAMETER ( TEN81 = 10.0d0/81.0d0 )

C Fix some more numerical constants
      PI = 4 * ATAN(1.D0)
      BETA = 0.066725D0
      GAMMA = (1 - LOG(TWO)) / PI**2
      MU = BETA * PI**2 / 3
      KAPPA = 0.804D0
      CWC = 0.0079325D0

C Translate density and its gradient to new variables
      IF (nspin .EQ. 1) THEN
        D(1) = HALF * Dens(1)
        D(2) = D(1)
        DT = MAX( DENMIN, Dens(1) )
        DO 10 IX = 1,3
          GD(IX,1) = HALF * GDens(IX,1)
          GD(IX,2) = GD(IX,1)
          GDT(IX) = GDens(IX,1)
   10   CONTINUE
      ELSE
        D(1) = Dens(1)
        D(2) = Dens(2)
        DT = MAX( DENMIN, Dens(1)+Dens(2) )
        DO 20 IX = 1,3
          GD(IX,1) = GDens(IX,1)
          GD(IX,2) = GDens(IX,2)
          GDT(IX) = GDens(IX,1) + GDens(IX,2)
   20   CONTINUE
      ENDIF
      GDM(1) = SQRT( GD(1,1)**2 + GD(2,1)**2 + GD(3,1)**2 )
      GDM(2) = SQRT( GD(1,2)**2 + GD(2,2)**2 + GD(3,2)**2 )
      GDMT   = SQRT( GDT(1)**2  + GDT(2)**2  + GDT(3)**2  )
      GDMT = MAX( GDMIN, GDMT )

C Find local correlation energy and potential
      CALL PW92C( 2, D, ECUNIF, VCUNIF )

C Find total correlation energy
      RS = ( 3 / (4*PI*DT) )**THD
      KF = (3 * PI**2 * DT)**THD
      KS = SQRT( 4 * KF / PI )
      ZETA = ( D(1) - D(2) ) / DT
      ZETA = MAX( -1.D0+DENMIN, ZETA )
      ZETA = MIN(  1.D0-DENMIN, ZETA )
      PHI = HALF * ( (1+ZETA)**TWOTHD + (1-ZETA)**TWOTHD )
      T = GDMT / (2 * PHI * KS * DT)
      F1 = ECUNIF / GAMMA / PHI**3
      F2 = EXP(-F1)
      A = BETA / GAMMA / (F2-1)
      F3 = T**2 + A * T**4
      F4 = BETA/GAMMA * F3 / (1 + A*F3)
      H = GAMMA * PHI**3 * LOG( 1 + F4 )
      FC = ECUNIF + H

C Find correlation energy derivatives
      DRSDD = - (THD * RS / DT)
      DKFDD =   THD * KF / DT
      DKSDD = HALF * KS * DKFDD / KF
      DZDD(1) =   1 / DT - ZETA / DT
      DZDD(2) = - (1 / DT) - ZETA / DT
      DPDZ = HALF * TWOTHD * ( 1/(1+ZETA)**THD - 1/(1-ZETA)**THD )
      DO 40 IS = 1,2
        DECUDD = ( VCUNIF(IS) - ECUNIF ) / DT
        DPDD = DPDZ * DZDD(IS)
        DTDD = (- T) * ( DPDD/PHI + DKSDD/KS + 1/DT )
        DF1DD = F1 * ( DECUDD/ECUNIF - 3*DPDD/PHI )
        DF2DD = (- F2) * DF1DD
        DADD = (- A) * DF2DD / (F2-1)
        DF3DD = (2*T + 4*A*T**3) * DTDD + DADD * T**4
        DF4DD = F4 * ( DF3DD/F3 - (DADD*F3+A*DF3DD)/(1+A*F3) )
        DHDD = 3 * H * DPDD / PHI
        DHDD = DHDD + GAMMA * PHI**3 * DF4DD / (1+F4)
        DFCDD(IS) = VCUNIF(IS) + H + DT * DHDD

        DO 30 IX = 1,3
          DTDGD = (T / GDMT) * GDT(IX) / GDMT
          DF3DGD = DTDGD * ( 2 * T + 4 * A * T**3 )
          DF4DGD = F4 * DF3DGD * ( 1/F3 - A/(1+A*F3) ) 
          DHDGD = GAMMA * PHI**3 * DF4DGD / (1+F4)
          DFCDGD(IX,IS) = DT * DHDGD
   30   CONTINUE
   40 CONTINUE

C Find exchange energy and potential
      FX = 0
      DO 60 IS = 1,2
        DS(IS)   = MAX( DENMIN, 2 * D(IS) )
        GDMS = MAX( GDMIN, 2 * GDM(IS) )
        KFS = (3 * PI**2 * DS(IS))**THD
        S = GDMS / (2 * KFS * DS(IS))
c
c For PBE: 
c
c       x = MU * S**2
c       dxds = 2*MU*S
c
c Wu-Cohen form:
c
        XWC= TEN81 * s**2 + (MU- TEN81) * 
     .       S**2 * exp(-S**2) + log(1+ CWC * S**4)
        DXWCDS = 2 * TEN81 * S + (MU - TEN81) * exp(-S**2) *
     .           2*S * (1 - S*S) + 4 * CWC * S**3 / (1 + CWC * S**4) 
c-------------------

        F1 = 1 +  XWC / KAPPA
        F = 1 + KAPPA - KAPPA / F1
c
c       Note nspin=1 in call to exchng...
c
        CALL EXCHNG( IREL, 1, DS(IS), EXUNIF, VXUNIF(IS) )
        FX = FX + DS(IS) * EXUNIF * F

        DKFDD = THD * KFS / DS(IS)
        DSDD = S * ( -(DKFDD/KFS) - 1/DS(IS) )
        DF1DD = DXWCDS * DSDD / KAPPA 
        DFDD = KAPPA * DF1DD / F1**2
        DFXDD(IS) = VXUNIF(IS) * F + DS(IS) * EXUNIF * DFDD

        DO 50 IX = 1,3
          GDS = 2 * GD(IX,IS)
          DSDGD = (S / GDMS) * GDS / GDMS
          DF1DGD = DXWCDS * DSDGD / KAPPA
          DFDGD = KAPPA * DF1DGD / F1**2
          DFXDGD(IX,IS) = DS(IS) * EXUNIF * DFDGD
   50   CONTINUE
   60 CONTINUE
      FX = HALF * FX / DT

C Set output arguments
      EX = FX
      EC = FC
      DO 90 IS = 1,nspin
        DEXDD(IS) = DFXDD(IS)
        DECDD(IS) = DFCDD(IS)
        DO 80 IX = 1,3
          DEXDGD(IX,IS) = DFXDGD(IX,IS)
          DECDGD(IX,IS) = DFCDGD(IX,IS)
   80   CONTINUE
   90 CONTINUE

      END

      SUBROUTINE PBESOLXC( IREL, nspin, Dens, GDens,
     .                  EX, EC, DEXDD, DECDD, DEXDGD, DECDGD )

C *********************************************************************
C Implements Perdew-Burke-Ernzerhof Generalized-Gradient-Approximation.
C with the revised parameters for solids (PBEsol).
C Ref: J.P.Perdew et al, PRL 100, 136406 (2008)
C Written by L.C.Balbas and J.M.Soler for PBE. December 1996. 
C Modified by J.D. Gale for PBEsol. May 2009.
C ******** INPUT ******************************************************
C INTEGER IREL           : Relativistic-exchange switch (0=No, 1=Yes)
C INTEGER nspin          : Number of spin polarizations (1 or 2)
C REAL*8  Dens(nspin)    : Total electron density (if nspin=1) or
C                           spin electron density (if nspin=2)
C REAL*8  GDens(3,nspin) : Total or spin density gradient
C ******** OUTPUT *****************************************************
C REAL*8  EX             : Exchange energy density
C REAL*8  EC             : Correlation energy density
C REAL*8  DEXDD(nspin)   : Partial derivative
C                           d(DensTot*Ex)/dDens(ispin),
C                           where DensTot = Sum_ispin( Dens(ispin) )
C                          For a constant density, this is the
C                          exchange potential
C REAL*8  DECDD(nspin)   : Partial derivative
C                           d(DensTot*Ec)/dDens(ispin),
C                           where DensTot = Sum_ispin( Dens(ispin) )
C                          For a constant density, this is the
C                          correlation potential
C REAL*8  DEXDGD(3,nspin): Partial derivative
C                           d(DensTot*Ex)/d(GradDens(i,ispin))
C REAL*8  DECDGD(3,nspin): Partial derivative
C                           d(DensTot*Ec)/d(GradDens(i,ispin))
C ********* UNITS ****************************************************
C Lengths in Bohr
C Densities in electrons per Bohr**3
C Energies in Hartrees
C Gradient vectors in cartesian coordinates
C ********* ROUTINES CALLED ******************************************
C EXCHNG, PW92C
C ********************************************************************

      use precision, only : dp

      implicit          none
      INTEGER           IREL, nspin
      real(dp)          Dens(nspin), DECDD(nspin), DECDGD(3,nspin),
     .                  DEXDD(nspin), DEXDGD(3,nspin), GDens(3,nspin)

C Internal variables
      INTEGER
     .  IS, IX

      real(dp)
     .  A, BETA, D(2), DADD, DECUDD, DENMIN, 
     .  DF1DD, DF2DD, DF3DD, DF4DD, DF1DGD, DF3DGD, DF4DGD,
     .  DFCDD(2), DFCDGD(3,2), DFDD, DFDGD, DFXDD(2), DFXDGD(3,2),
     .  DHDD, DHDGD, DKFDD, DKSDD, DPDD, DPDZ, DRSDD, 
     .  DS(2), DSDD, DSDGD, DT, DTDD, DTDGD, DZDD(2), 
     .  EC, ECUNIF, EX, EXUNIF,
     .  F, F1, F2, F3, F4, FC, FX, FOUTHD,
     .  GAMMA, GD(3,2), GDM(2), GDMIN, GDMS, GDMT, GDS, GDT(3),
     .  H, HALF, KAPPA, KF, KFS, KS, MU, PHI, PI, RS, S,
     .  T, THD, THRHLF, TWO, TWOTHD, VCUNIF(2), VXUNIF(2), ZETA

C Lower bounds of density and its gradient to avoid divisions by zero
      PARAMETER ( DENMIN = 1.D-12 )
      PARAMETER ( GDMIN  = 1.D-12 )

C Fix some numerical parameters
      PARAMETER ( FOUTHD=4.D0/3.D0, HALF=0.5D0,
     .            THD=1.D0/3.D0, THRHLF=1.5D0,
     .            TWO=2.D0, TWOTHD=2.D0/3.D0 )

C Fix some more numerical constants
      PI = 4 * ATAN(1.D0)
      BETA = 0.046d0
      GAMMA = (1 - LOG(TWO)) / PI**2
      MU = 10.0d0/81.0d0
      KAPPA = 0.804D0

C Translate density and its gradient to new variables
      IF (nspin .EQ. 1) THEN
        D(1) = HALF * Dens(1)
        D(2) = D(1)
        DT = MAX( DENMIN, Dens(1) )
        DO 10 IX = 1,3
          GD(IX,1) = HALF * GDens(IX,1)
          GD(IX,2) = GD(IX,1)
          GDT(IX) = GDens(IX,1)
   10   CONTINUE
      ELSE
        D(1) = Dens(1)
        D(2) = Dens(2)
        DT = MAX( DENMIN, Dens(1)+Dens(2) )
        DO 20 IX = 1,3
          GD(IX,1) = GDens(IX,1)
          GD(IX,2) = GDens(IX,2)
          GDT(IX) = GDens(IX,1) + GDens(IX,2)
   20   CONTINUE
      ENDIF
      GDM(1) = SQRT( GD(1,1)**2 + GD(2,1)**2 + GD(3,1)**2 )
      GDM(2) = SQRT( GD(1,2)**2 + GD(2,2)**2 + GD(3,2)**2 )
      GDMT   = SQRT( GDT(1)**2  + GDT(2)**2  + GDT(3)**2  )
      GDMT = MAX( GDMIN, GDMT )

C Find local correlation energy and potential
      CALL PW92C( 2, D, ECUNIF, VCUNIF )

C Find total correlation energy
      RS = ( 3 / (4*PI*DT) )**THD
      KF = (3 * PI**2 * DT)**THD
      KS = SQRT( 4 * KF / PI )
      ZETA = ( D(1) - D(2) ) / DT
      ZETA = MAX( -1.D0+DENMIN, ZETA )
      ZETA = MIN(  1.D0-DENMIN, ZETA )
      PHI = HALF * ( (1+ZETA)**TWOTHD + (1-ZETA)**TWOTHD )
      T = GDMT / (2 * PHI * KS * DT)
      F1 = ECUNIF / GAMMA / PHI**3
      F2 = EXP(-F1)
      A = BETA / GAMMA / (F2-1)
      F3 = T**2 + A * T**4
      F4 = BETA/GAMMA * F3 / (1 + A*F3)
      H = GAMMA * PHI**3 * LOG( 1 + F4 )
      FC = ECUNIF + H

C Find correlation energy derivatives
      DRSDD = - (THD * RS / DT)
      DKFDD =   THD * KF / DT
      DKSDD = HALF * KS * DKFDD / KF
      DZDD(1) =   1 / DT - ZETA / DT
      DZDD(2) = - (1 / DT) - ZETA / DT
      DPDZ = HALF * TWOTHD * ( 1/(1+ZETA)**THD - 1/(1-ZETA)**THD )
      DO 40 IS = 1,2
        DECUDD = ( VCUNIF(IS) - ECUNIF ) / DT
        DPDD = DPDZ * DZDD(IS)
        DTDD = (- T) * ( DPDD/PHI + DKSDD/KS + 1/DT )
        DF1DD = F1 * ( DECUDD/ECUNIF - 3*DPDD/PHI )
        DF2DD = (- F2) * DF1DD
        DADD = (- A) * DF2DD / (F2-1)
        DF3DD = (2*T + 4*A*T**3) * DTDD + DADD * T**4
        DF4DD = F4 * ( DF3DD/F3 - (DADD*F3+A*DF3DD)/(1+A*F3) )
        DHDD = 3 * H * DPDD / PHI
        DHDD = DHDD + GAMMA * PHI**3 * DF4DD / (1+F4)
        DFCDD(IS) = VCUNIF(IS) + H + DT * DHDD

        DO 30 IX = 1,3
          DTDGD = (T / GDMT) * GDT(IX) / GDMT
          DF3DGD = DTDGD * ( 2 * T + 4 * A * T**3 )
          DF4DGD = F4 * DF3DGD * ( 1/F3 - A/(1+A*F3) ) 
          DHDGD = GAMMA * PHI**3 * DF4DGD / (1+F4)
          DFCDGD(IX,IS) = DT * DHDGD
   30   CONTINUE
   40 CONTINUE

C Find exchange energy and potential
      FX = 0
      DO 60 IS = 1,2
        DS(IS)   = MAX( DENMIN, 2 * D(IS) )
        GDMS = MAX( GDMIN, 2 * GDM(IS) )
        KFS = (3 * PI**2 * DS(IS))**THD
        S = GDMS / (2 * KFS * DS(IS))
        F1 = 1 + MU * S**2 / KAPPA
        F = 1 + KAPPA - KAPPA / F1
c
c       Note nspin=1 in call to exchng...
c
        CALL EXCHNG( IREL, 1, DS(IS), EXUNIF, VXUNIF(IS) )
        FX = FX + DS(IS) * EXUNIF * F

        DKFDD = THD * KFS / DS(IS)
        DSDD = S * ( -(DKFDD/KFS) - 1/DS(IS) )
        DF1DD = 2 * (F1-1) * DSDD / S
        DFDD = KAPPA * DF1DD / F1**2
        DFXDD(IS) = VXUNIF(IS) * F + DS(IS) * EXUNIF * DFDD

        DO 50 IX = 1,3
          GDS = 2 * GD(IX,IS)
          DSDGD = (S / GDMS) * GDS / GDMS
          DF1DGD = 2 * MU * S * DSDGD / KAPPA
          DFDGD = KAPPA * DF1DGD / F1**2
          DFXDGD(IX,IS) = DS(IS) * EXUNIF * DFDGD
   50   CONTINUE
   60 CONTINUE
      FX = HALF * FX / DT

C Set output arguments
      EX = FX
      EC = FC
      DO 90 IS = 1,nspin
        DEXDD(IS) = DFXDD(IS)
        DECDD(IS) = DFCDD(IS)
        DO 80 IX = 1,3
          DEXDGD(IX,IS) = DFXDGD(IX,IS)
          DECDGD(IX,IS) = DFCDGD(IX,IS)
   80   CONTINUE
   90 CONTINUE

      END

