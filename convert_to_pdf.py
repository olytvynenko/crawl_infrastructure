#!/usr/bin/env python3
"""
Convert DOCX to PDF using docx2pdf or alternative methods
"""
import sys
import subprocess
import os

def convert_with_docx2pdf(docx_file, pdf_file):
    """Try to convert using docx2pdf (works best on Windows/Mac with MS Office)"""
    try:
        from docx2pdf import convert
        print("Converting using docx2pdf...")
        convert(docx_file, pdf_file)
        return True
    except ImportError:
        print("docx2pdf not available, trying to install...")
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install", "docx2pdf"])
            from docx2pdf import convert
            convert(docx_file, pdf_file)
            return True
        except:
            print("docx2pdf installation failed or not supported on this system")
            return False
    except Exception as e:
        print(f"docx2pdf conversion failed: {e}")
        return False

def convert_with_pypandoc(docx_file, pdf_file):
    """Try to convert using pypandoc"""
    try:
        import pypandoc
        print("Converting using pypandoc...")
        pypandoc.convert_file(docx_file, 'pdf', outputfile=pdf_file)
        return True
    except ImportError:
        print("pypandoc not available, trying to install...")
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install", "pypandoc"])
            import pypandoc
            # Download pandoc if not installed
            pypandoc.download_pandoc()
            pypandoc.convert_file(docx_file, 'pdf', outputfile=pdf_file)
            return True
        except:
            print("pypandoc installation failed")
            return False
    except Exception as e:
        print(f"pypandoc conversion failed: {e}")
        return False

def convert_with_libreoffice(docx_file, pdf_file):
    """Try to convert using LibreOffice command line"""
    try:
        # Common LibreOffice executable locations
        libreoffice_paths = [
            '/Applications/LibreOffice.app/Contents/MacOS/soffice',  # macOS
            'soffice',  # Linux/Unix (in PATH)
            'libreoffice',  # Alternative Linux command
        ]
        
        for lo_path in libreoffice_paths:
            try:
                print(f"Trying LibreOffice at: {lo_path}")
                # Convert to PDF in the same directory
                cmd = [lo_path, '--headless', '--convert-to', 'pdf', '--outdir', 
                       os.path.dirname(os.path.abspath(docx_file)), docx_file]
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                
                if result.returncode == 0:
                    print("LibreOffice conversion successful")
                    # LibreOffice creates PDF with same name in output directory
                    generated_pdf = os.path.splitext(docx_file)[0] + '.pdf'
                    if os.path.exists(generated_pdf) and generated_pdf != pdf_file:
                        os.rename(generated_pdf, pdf_file)
                    return True
            except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
                continue
        
        print("LibreOffice not found or conversion failed")
        return False
    except Exception as e:
        print(f"LibreOffice conversion failed: {e}")
        return False

def create_simple_pdf_with_reportlab(docx_file, pdf_file):
    """Create a simple PDF with basic content extraction"""
    try:
        from reportlab.lib.pagesizes import letter, A4
        from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, PageBreak
        from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
        from reportlab.lib.units import inch
        from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY
        from docx import Document
        
        print("Creating PDF using ReportLab...")
        
        # Read DOCX
        doc = Document(docx_file)
        
        # Create PDF
        pdf = SimpleDocTemplate(pdf_file, pagesize=A4)
        styles = getSampleStyleSheet()
        
        # Custom styles
        title_style = ParagraphStyle(
            'CustomTitle',
            parent=styles['Heading1'],
            fontSize=24,
            textColor='navy',
            alignment=TA_CENTER,
            spaceAfter=30
        )
        
        heading1_style = ParagraphStyle(
            'CustomHeading1',
            parent=styles['Heading1'],
            fontSize=18,
            spaceAfter=12
        )
        
        heading2_style = ParagraphStyle(
            'CustomHeading2',
            parent=styles['Heading2'],
            fontSize=14,
            spaceAfter=10
        )
        
        code_style = ParagraphStyle(
            'Code',
            parent=styles['Code'],
            fontSize=8,
            leftIndent=20
        )
        
        # Build story
        story = []
        
        # Title page
        story.append(Paragraph("Crawl Infrastructure", title_style))
        story.append(Paragraph("Comprehensive Documentation", title_style))
        story.append(Spacer(1, 2*inch))
        story.append(Paragraph("AI Assistant", styles['Normal']))
        story.append(Paragraph("December 2024", styles['Normal']))
        story.append(PageBreak())
        
        # Process paragraphs from DOCX
        for para in doc.paragraphs:
            if para.text.strip():
                # Detect heading level by font size or style
                if para.style.name.startswith('CustomTitle'):
                    story.append(Paragraph(para.text, title_style))
                elif para.style.name.startswith('CustomHeading1'):
                    story.append(PageBreak())
                    story.append(Paragraph(para.text, heading1_style))
                elif para.style.name.startswith('CustomHeading2'):
                    story.append(Paragraph(para.text, heading2_style))
                elif para.style.name == 'CodeBlock':
                    # Handle code blocks
                    code_text = para.text.replace('<', '&lt;').replace('>', '&gt;')
                    story.append(Paragraph(code_text, code_style))
                else:
                    # Regular paragraph
                    text = para.text.replace('<', '&lt;').replace('>', '&gt;')
                    story.append(Paragraph(text, styles['Normal']))
                story.append(Spacer(1, 6))
        
        # Build PDF
        pdf.build(story)
        print(f"PDF created: {pdf_file}")
        return True
        
    except ImportError:
        print("ReportLab not available, installing...")
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install", "reportlab"])
            return create_simple_pdf_with_reportlab(docx_file, pdf_file)
        except:
            print("ReportLab installation failed")
            return False
    except Exception as e:
        print(f"ReportLab PDF creation failed: {e}")
        return False

def main():
    docx_file = "CRAWL_INFRASTRUCTURE_DOCUMENTATION.docx"
    pdf_file = "CRAWL_INFRASTRUCTURE_DOCUMENTATION.pdf"
    
    if not os.path.exists(docx_file):
        print(f"Error: {docx_file} not found!")
        return False
    
    # Try different conversion methods in order of preference
    methods = [
        ("docx2pdf", convert_with_docx2pdf),
        ("LibreOffice", convert_with_libreoffice),
        ("pypandoc", convert_with_pypandoc),
        ("ReportLab", create_simple_pdf_with_reportlab)
    ]
    
    for method_name, method_func in methods:
        print(f"\nTrying {method_name}...")
        if method_func(docx_file, pdf_file):
            if os.path.exists(pdf_file):
                print(f"\nSuccess! PDF created: {pdf_file}")
                print(f"File size: {os.path.getsize(pdf_file) / 1024:.1f} KB")
                return True
    
    print("\nAll conversion methods failed. Please install LibreOffice or MS Office.")
    return False

if __name__ == "__main__":
    main()